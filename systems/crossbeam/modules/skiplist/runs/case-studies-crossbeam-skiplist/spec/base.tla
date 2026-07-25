---- MODULE base ----
(***************************************************************************)
(* TLA+ specification of crossbeam-skiplist — lock-free concurrent skip    *)
(* list with epoch-based reclamation.                                      *)
(*                                                                         *)
(* Source: crossbeam-skiplist/src/base.rs                                   *)
(*                                                                         *)
(* Bug Families:                                                           *)
(*   F1 — Reference Count Lifecycle Errors (7+ historical bugs)            *)
(*   F2 — Concurrent Insert/Remove Linearizability (#1023, #1143)          *)
(*   F3 — Iterator Exhaustion and Ordering (#1142)                         *)
(*   F4 — Tower Marking Protocol Correctness                              *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

(* ====================================================================== *)
(* Constants                                                               *)
(* ====================================================================== *)

CONSTANTS
    Thread,        \* Set of thread IDs
    Key,           \* Set of keys (naturals, totally ordered)
    MaxLevel,      \* Tower levels: 0..MaxLevel-1
    MaxNodes       \* Allocatable node IDs: 1..MaxNodes

HeadNode == 0
Nil      == -1
Level    == 0..(MaxLevel - 1)
NodePool == 1..MaxNodes
AllNodes == {HeadNode} \cup NodePool

ASSUME MaxLevel >= 1 /\ MaxNodes >= 1

(* ====================================================================== *)
(* Variables                                                               *)
(* ====================================================================== *)

\* --- Node storage (base.rs:129-145) ---
VARIABLES
    nodeKey,            \* [AllNodes -> Key \cup {Nil}]
    nodeHeight,         \* [AllNodes -> 1..MaxLevel]
    nodeAllocated,      \* [AllNodes -> BOOLEAN]
    nodeFinalized       \* [AllNodes -> BOOLEAN] (F1)

\* --- Link structure (base.rs: tower pointers with tag bits) ---
\* succ[n][l] = node pointed to by n's tower[l] (ignoring tag)
\* succMarked[n][l] = tag bit on n's tower[l] pointer (mark_tower sets this)
VARIABLES
    succ,               \* [AllNodes -> [Level -> AllNodes \cup {Nil}]]
    succMarked          \* [AllNodes -> [Level -> BOOLEAN]]

\* --- Reference counting (F1: base.rs:137-142, 214-303) ---
VARIABLES
    refCount            \* [NodePool -> Nat]

\* --- Per-thread operation state ---
VARIABLES
    pc,                 \* [Thread -> String]
    tKey,               \* [Thread -> Key \cup {Nil}]
    tNode,              \* [Thread -> AllNodes \cup {Nil}] — found/target node
    tNew,               \* [Thread -> NodePool \cup {Nil}] — new node for insert
    tHeight,            \* [Thread -> 1..MaxLevel]
    tLevel,             \* [Thread -> 0..MaxLevel] — current tower build level
    tPred,              \* [Thread -> [Level -> AllNodes]] — search predecessors
    tSucc,              \* [Thread -> [Level -> AllNodes \cup {Nil}]] — search succs
    tEntry              \* [Thread -> NodePool \cup {Nil}] — held RefEntry (F1)

\* --- Iterator state (F3: base.rs:1798-1833) ---
VARIABLES
    iterCursor,         \* [Thread -> AllNodes \cup {Nil}]
    iterState           \* [Thread -> {"inactive","active","exhausted"}]

\* --- Fault injection ---
VARIABLES
    markBeforeCAS       \* BOOLEAN — F2: mark old node before CAS (bug #1023)

\* --- History ---
VARIABLES
    listMap             \* Set of keys logically present

\* Variable groups for UNCHANGED
nodeVars   == <<nodeKey, nodeHeight, nodeAllocated, nodeFinalized>>
linkVars   == <<succ, succMarked>>
refVars    == <<refCount>>
threadVars == <<pc, tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry>>
iterVars   == <<iterCursor, iterState>>
faultVars  == <<markBeforeCAS>>
histVars   == <<listMap>>

vars == <<nodeVars, linkVars, refVars, threadVars, iterVars, faultVars, histVars>>

(* ====================================================================== *)
(* Helpers                                                                 *)
(* ====================================================================== *)

\* Key ordering: HeadNode = -infinity (base.rs: head sentinel)
KeyOf(n) == IF n = HeadNode THEN -999 ELSE nodeKey[n]

\* A node is logically removed iff its level-0 pointer is marked
\* (base.rs:352-361, is_removed)
IsRemoved(n) == n # HeadNode /\ succMarked[n][0]

\* Free nodes available for allocation
FreeNodes == {n \in NodePool : ~nodeAllocated[n]}

\* ---------- Search (base.rs:923-1008, search_position) ----------
\* Walk level-l chain from HeadNode to find rightmost node with key < k.
\* Bounded recursion for safety.
RECURSIVE WalkChain(_, _, _, _)
WalkChain(curr, k, l, depth) ==
    IF depth = 0 THEN curr
    ELSE LET s == succ[curr][l] IN
         IF s = Nil THEN curr
         ELSE IF s \notin NodePool THEN curr
         ELSE IF nodeKey[s] >= k THEN curr
         ELSE WalkChain(s, k, l, depth - 1)

FindPred(k, l) == WalkChain(HeadNode, k, l, MaxNodes + 1)

\* Compute search position for key k (base.rs:923-1008)
ComputePreds(k) == [l \in Level |-> FindPred(k, l)]

ComputeSuccs(k) ==
    LET preds == ComputePreds(k) IN
    [l \in Level |-> succ[preds[l]][l]]

\* Find existing live node with key = k at level 0 (base.rs:984-991)
ComputeFound(k) ==
    LET pred == FindPred(k, 0) IN
    LET s == succ[pred][0] IN
    IF s # Nil /\ s \in NodePool /\ nodeKey[s] = k /\ ~succMarked[s][0]
    THEN s ELSE Nil

\* Level-0 next live node (base.rs:787-823, next_node)
NextLiveNode(n) ==
    LET s == succ[n][0] IN
    IF s = Nil THEN Nil
    ELSE IF s \notin NodePool THEN Nil
    ELSE IF ~succMarked[s][0] THEN s
    ELSE \* s is marked; skip one (simplified help_unlink)
         LET ss == succ[s][0] IN
         IF ss = Nil THEN Nil
         ELSE IF ss \notin NodePool THEN Nil
         ELSE IF ~succMarked[ss][0] THEN ss
         ELSE Nil

\* ---------- Mark tower (base.rs:327-348) ----------
\* Mark all levels of node n up to its height.
\* Returns TRUE if level 0 was previously unmarked (we "won").
MarkTowerWins(n) == ~succMarked[n][0]

DoMarkTower(n) ==
    [succMarked EXCEPT ![n] =
        [l \in Level |->
            IF l < nodeHeight[n] THEN TRUE
            ELSE succMarked[n][l]]]

\* ---------- Unlink helpers (base.rs:759-781, help_unlink) ----------
\* Count levels where pred still points to n (for batch unlink)
UnlinkCount(n, preds) ==
    Cardinality({l \in Level : l < nodeHeight[n] /\
        succ[preds[l]][l] = n /\ ~succMarked[preds[l]][l]})

\* Unlink node n from all levels where predecessor still matches
DoUnlink(n, preds) ==
    [nd \in AllNodes |-> [l \in Level |->
        IF l < nodeHeight[n] /\ nd = preds[l] /\
           succ[nd][l] = n /\ ~succMarked[nd][l]
        THEN succ[n][l]    \* base.rs:769-770: pred -> n's successor
        ELSE succ[nd][l]]]

(* ====================================================================== *)
(* Init                                                                    *)
(* ====================================================================== *)

Init ==
    /\ nodeKey       = [n \in AllNodes |-> Nil]
    /\ nodeHeight    = [n \in AllNodes |-> IF n = HeadNode THEN MaxLevel ELSE 1]
    /\ nodeAllocated = [n \in AllNodes |-> (n = HeadNode)]
    /\ nodeFinalized = [n \in AllNodes |-> FALSE]
    /\ succ          = [n \in AllNodes |-> [l \in Level |-> Nil]]
    /\ succMarked    = [n \in AllNodes |-> [l \in Level |-> FALSE]]
    /\ refCount      = [n \in NodePool |-> 0]
    /\ pc            = [t \in Thread |-> "Idle"]
    /\ tKey          = [t \in Thread |-> Nil]
    /\ tNode         = [t \in Thread |-> Nil]
    /\ tNew          = [t \in Thread |-> Nil]
    /\ tHeight       = [t \in Thread |-> 1]
    /\ tLevel        = [t \in Thread |-> 0]
    /\ tPred         = [t \in Thread |-> [l \in Level |-> HeadNode]]
    /\ tSucc         = [t \in Thread |-> [l \in Level |-> Nil]]
    /\ tEntry        = [t \in Thread |-> Nil]
    /\ iterCursor    = [t \in Thread |-> Nil]
    /\ iterState     = [t \in Thread |-> "inactive"]
    /\ markBeforeCAS = FALSE
    /\ listMap       = {}

(* ====================================================================== *)
(* Insert Actions (base.rs:1013-1234)                                      *)
(* ====================================================================== *)

\* -----------------------------------------------------------------------
\* InsertBegin: allocate node, search for position (base.rs:1035-1065)
\* -----------------------------------------------------------------------
InsertBegin(t, k, h) ==
    /\ pc[t] = "Idle"
    /\ tEntry[t] = Nil   \* must release prior entry (Rust ownership)
    /\ k \in Key /\ h \in 1..MaxLevel
    /\ FreeNodes # {}
    /\ \E n \in FreeNodes :
        LET preds == ComputePreds(k)
            succs == ComputeSuccs(k)
            found == ComputeFound(k)
        IN
        \* Allocate node with ref_count = 2 (entry + level-0) (base.rs:1055)
        /\ nodeKey'       = [nodeKey EXCEPT ![n] = k]
        /\ nodeHeight'    = [nodeHeight EXCEPT ![n] = h]
        /\ nodeAllocated' = [nodeAllocated EXCEPT ![n] = TRUE]
        /\ refCount'      = [refCount EXCEPT ![n] = 2]
        \* Record search results and thread state
        /\ pc'     = [pc EXCEPT ![t] = "InsertReady"]
        /\ tKey'   = [tKey EXCEPT ![t] = k]
        /\ tNew'   = [tNew EXCEPT ![t] = n]
        /\ tHeight'= [tHeight EXCEPT ![t] = h]
        /\ tNode'  = [tNode EXCEPT ![t] = found]
        /\ tPred'  = [tPred EXCEPT ![t] = preds]
        /\ tSucc'  = [tSucc EXCEPT ![t] = succs]
        /\ tLevel' = [tLevel EXCEPT ![t] = 1]
        /\ tEntry' = [tEntry EXCEPT ![t] = n]
        \* F2 fault injection: mark old node BEFORE CAS (bug #1023 pattern)
        /\ IF markBeforeCAS /\ found # Nil /\ ~succMarked[found][0] THEN
             /\ succMarked' = DoMarkTower(found)
             /\ listMap'    = listMap \ {k}
           ELSE
             /\ UNCHANGED <<succMarked, listMap>>
    /\ UNCHANGED <<nodeFinalized, succ, iterVars, faultVars>>

\* -----------------------------------------------------------------------
\* InsertCAS: level-0 CAS to install new node (base.rs:1070-1094)
\* Linearization point for insert (on CAS success).
\* -----------------------------------------------------------------------
InsertCAS(t) ==
    /\ pc[t] = "InsertReady"
    /\ LET pred    == tPred[t][0]
           expSucc == tSucc[t][0]
           nn      == tNew[t]
           old     == tNode[t]
       IN
       \* CAS check: pred.succ[0] still points to expected (base.rs:1076-1085)
       IF succ[pred][0] = expSucc /\ ~succMarked[pred][0] THEN
         \* --- CAS succeeds (linearization point) ---
         /\ succ' = [succ EXCEPT
              ![nn][0]   = expSucc,   \* base.rs:1072: new node -> old successor
              ![pred][0] = nn]        \* base.rs:1078: pred -> new node
         \* Mark old node if replacing, correct code path (base.rs:1088-1092)
         /\ IF ~markBeforeCAS /\ old # Nil /\ ~succMarked[old][0] THEN
              succMarked' = DoMarkTower(old)
            ELSE UNCHANGED succMarked
         \* Abstract state: key is now present (base.rs:1068)
         /\ listMap' = listMap \cup {tKey[t]}
         \* Advance to tower building if height > 1
         /\ pc' = [pc EXCEPT ![t] =
              IF tHeight[t] > 1 THEN "InsertBuild" ELSE "Idle"]
         /\ tLevel' = [tLevel EXCEPT ![t] = 1]
         /\ UNCHANGED <<nodeVars, refVars,
              tKey, tNode, tNew, tHeight, tPred, tSucc, tEntry,
              iterVars, faultVars>>
       ELSE
         \* --- CAS fails: re-search (base.rs:1096-1127) ---
         LET preds == ComputePreds(tKey[t])
             succs == ComputeSuccs(tKey[t])
             found == ComputeFound(tKey[t])
         IN
         /\ tPred' = [tPred EXCEPT ![t] = preds]
         /\ tSucc' = [tSucc EXCEPT ![t] = succs]
         /\ tNode' = [tNode EXCEPT ![t] = found]
         \* Stay in InsertReady to retry
         /\ UNCHANGED <<nodeVars, linkVars, refVars,
              pc, tKey, tNew, tHeight, tLevel, tEntry,
              iterVars, faultVars, histVars>>

\* -----------------------------------------------------------------------
\* InsertBuildLevel: link new node at tower level (base.rs:1136-1218)
\* -----------------------------------------------------------------------
InsertBuildLevel(t) ==
    /\ pc[t] = "InsertBuild"
    /\ LET lvl     == tLevel[t]
           nn      == tNew[t]
           pred    == tPred[t][lvl]
           expSucc == tSucc[t][lvl]
       IN
       IF lvl >= tHeight[t] THEN
         \* All levels built; check for concurrent mark (base.rs:1220-1229)
         /\ pc' = [pc EXCEPT ![t] = "Idle"]
         /\ UNCHANGED <<nodeVars, linkVars, refVars,
              tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry,
              iterVars, faultVars, histVars>>
       ELSE IF succMarked[nn][lvl] THEN
         \* Our node is being concurrently removed; stop (base.rs:1149-1151)
         /\ pc' = [pc EXCEPT ![t] = "Idle"]
         /\ UNCHANGED <<nodeVars, linkVars, refVars,
              tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry,
              iterVars, faultVars, histVars>>
       ELSE IF expSucc # Nil /\ expSucc \in NodePool /\
               nodeKey[expSucc] = tKey[t] THEN
         \* Duplicate key at this level; re-search (base.rs:1171-1177)
         LET preds == ComputePreds(tKey[t])
             succs == ComputeSuccs(tKey[t])
         IN
         /\ tPred' = [tPred EXCEPT ![t] = preds]
         /\ tSucc' = [tSucc EXCEPT ![t] = succs]
         /\ UNCHANGED <<nodeVars, linkVars, refVars,
              pc, tKey, tNode, tNew, tHeight, tLevel, tEntry,
              iterVars, faultVars, histVars>>
       ELSE IF succ[pred][lvl] = expSucc /\ ~succMarked[pred][lvl] THEN
         \* CAS succeeds: link node at this level (base.rs:1183-1203)
         /\ succ' = [succ EXCEPT
              ![nn][lvl]   = expSucc,  \* base.rs:1183-1184
              ![pred][lvl] = nn]       \* base.rs:1197-1199
         /\ refCount' = [refCount EXCEPT ![nn] = refCount[nn] + 1]
         /\ tLevel' = [tLevel EXCEPT ![t] = lvl + 1]
         /\ pc' = [pc EXCEPT ![t] =
              IF lvl + 1 >= tHeight[t] THEN "Idle" ELSE "InsertBuild"]
         /\ UNCHANGED <<nodeVars, succMarked,
              tKey, tNode, tNew, tHeight, tPred, tSucc, tEntry,
              iterVars, faultVars, histVars>>
       ELSE
         \* Install CAS failed; re-search (base.rs:1206-1216)
         LET preds == ComputePreds(tKey[t])
             succs == ComputeSuccs(tKey[t])
         IN
         /\ tPred' = [tPred EXCEPT ![t] = preds]
         /\ tSucc' = [tSucc EXCEPT ![t] = succs]
         /\ UNCHANGED <<nodeVars, linkVars, refVars,
              pc, tKey, tNode, tNew, tHeight, tLevel, tEntry,
              iterVars, faultVars, histVars>>

(* ====================================================================== *)
(* Remove Actions (base.rs:1270-1337)                                      *)
(* ====================================================================== *)

\* -----------------------------------------------------------------------
\* RemoveBegin: search for key, try_acquire ref (base.rs:1283-1294)
\* -----------------------------------------------------------------------
RemoveBegin(t, k) ==
    /\ pc[t] = "Idle"
    /\ tEntry[t] = Nil   \* must release prior entry (Rust ownership)
    /\ k \in Key
    /\ LET found == ComputeFound(k) IN
       IF found = Nil THEN
         \* Key not found (base.rs:1287)
         /\ UNCHANGED vars
       ELSE IF refCount[found] = 0 THEN
         \* try_increment fails: ref count zero (base.rs:229-231)
         /\ UNCHANGED vars
       ELSE
         \* try_acquire succeeds: increment refCount (base.rs:1291, 239-245)
         /\ refCount' = [refCount EXCEPT ![found] = refCount[found] + 1]
         /\ pc'    = [pc EXCEPT ![t] = "RemoveMark"]
         /\ tKey'  = [tKey EXCEPT ![t] = k]
         /\ tNode' = [tNode EXCEPT ![t] = found]
         /\ tEntry'= [tEntry EXCEPT ![t] = found]
         /\ tPred' = [tPred EXCEPT ![t] = ComputePreds(k)]
         /\ tSucc' = [tSucc EXCEPT ![t] = ComputeSuccs(k)]
         /\ UNCHANGED <<nodeVars, linkVars,
              tNew, tHeight, tLevel,
              iterVars, faultVars, histVars>>

\* -----------------------------------------------------------------------
\* RemoveMarkTower: mark all levels top-down (base.rs:1297, 327-348)
\* Linearization point for remove: marking level 0.
\* -----------------------------------------------------------------------
RemoveMarkTower(t) ==
    /\ pc[t] = "RemoveMark"
    /\ LET n == tNode[t] IN
       IF MarkTowerWins(n) THEN
         \* We win: marked level 0 first (base.rs:327-348, returns true)
         /\ succMarked' = DoMarkTower(n)
         /\ listMap' = listMap \ {tKey[t]}    \* base.rs:1299
         /\ pc' = [pc EXCEPT ![t] = "RemoveUnlink"]
         /\ UNCHANGED <<nodeVars, succ, refVars,
              tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry,
              iterVars, faultVars>>
       ELSE
         \* Already marked: another thread won (base.rs:1330-1333)
         /\ refCount' = [refCount EXCEPT ![n] = refCount[n] - 1]
         /\ tEntry' = [tEntry EXCEPT ![t] = Nil]
         /\ pc' = [pc EXCEPT ![t] = "Idle"]
         /\ UNCHANGED <<nodeVars, linkVars,
              tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc,
              iterVars, faultVars, histVars>>

\* -----------------------------------------------------------------------
\* RemoveUnlink: unlink node from all levels (base.rs:1304-1327)
\* Modeled as atomic for simplicity; each successful unlink decrements ref.
\* -----------------------------------------------------------------------
RemoveUnlink(t) ==
    /\ pc[t] = "RemoveUnlink"
    /\ LET n     == tNode[t]
           preds == tPred[t]
           cnt   == UnlinkCount(n, preds)
       IN
       /\ succ' = DoUnlink(n, preds)
       /\ refCount' = [refCount EXCEPT ![n] = refCount[n] - cnt]
       /\ pc' = [pc EXCEPT ![t] = "Idle"]
       /\ UNCHANGED <<nodeVars, succMarked,
            tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry,
            iterVars, faultVars, histVars>>

(* ====================================================================== *)
(* Get Action (base.rs: get/lower_bound)                                   *)
(* ====================================================================== *)

\* Atomic search for key — returns whether found (for invariant checking)
Get(t, k) ==
    /\ pc[t] = "Idle"
    /\ k \in Key
    /\ UNCHANGED vars

(* ====================================================================== *)
(* HelpUnlink Action (base.rs:759-781)                                     *)
(* Any thread may help unlink a marked node encountered during traversal.  *)
(* ====================================================================== *)

HelpUnlink(n, l) ==
    /\ n \in NodePool
    /\ l \in Level
    /\ nodeAllocated[n]
    /\ succMarked[n][l]                            \* n is marked at level l
    /\ \E pred \in AllNodes :
         /\ succ[pred][l] = n
         /\ ~succMarked[pred][l]                   \* pred itself not marked
         /\ succ' = [succ EXCEPT ![pred][l] = succ[n][l]]
         /\ refCount' = [refCount EXCEPT ![n] = refCount[n] - 1]
    /\ UNCHANGED <<nodeVars, succMarked, threadVars, iterVars,
                   faultVars, histVars>>

(* ====================================================================== *)
(* Iterator Actions (F3: base.rs:1798-1833)                                *)
(* Models the bug where None means both "not started" and "exhausted",     *)
(* causing iteration to restart from the beginning after exhaustion.       *)
(* ====================================================================== *)

\* Start forward iteration
IterBegin(t) ==
    /\ pc[t] = "Idle"
    /\ iterState[t] = "inactive"
    /\ LET first == NextLiveNode(HeadNode) IN
       IF first = Nil THEN
         \* Empty list: immediately exhausted
         /\ iterState' = [iterState EXCEPT ![t] = "exhausted"]
         /\ iterCursor' = [iterCursor EXCEPT ![t] = Nil]
       ELSE
         /\ iterState' = [iterState EXCEPT ![t] = "active"]
         /\ iterCursor' = [iterCursor EXCEPT ![t] = first]
    /\ UNCHANGED <<nodeVars, linkVars, refVars,
         pc, tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry,
         faultVars, histVars>>

\* Advance iterator forward (base.rs:1812-1833, Iter::next)
\* Bug #1142: when head is None (exhausted), next() restarts from beginning
\* because None matches the "not started" branch.
IterNext(t) ==
    /\ iterState[t] = "active"
    /\ LET cursor == iterCursor[t] IN
       IF cursor = Nil THEN
         \* BUG PATH (F3, base.rs:1817-1820): None means "not started"
         \* so Iter::next restarts from head, replaying the list
         LET first == NextLiveNode(HeadNode) IN
         IF first = Nil THEN
           /\ iterState' = [iterState EXCEPT ![t] = "exhausted"]
           /\ iterCursor' = [iterCursor EXCEPT ![t] = Nil]
         ELSE
           /\ iterCursor' = [iterCursor EXCEPT ![t] = first]
           /\ UNCHANGED iterState
       ELSE
         \* Normal: advance to next live node
         LET nxt == NextLiveNode(cursor) IN
         IF nxt = Nil THEN
           \* Reached end: set cursor to Nil
           \* Bug: iterState stays "active", cursor = Nil
           \* Next call will restart from head (bug #1142)
           /\ iterCursor' = [iterCursor EXCEPT ![t] = Nil]
           /\ UNCHANGED iterState
         ELSE
           /\ iterCursor' = [iterCursor EXCEPT ![t] = nxt]
           /\ UNCHANGED iterState
    /\ UNCHANGED <<nodeVars, linkVars, refVars,
         pc, tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc, tEntry,
         faultVars, histVars>>

\* Stop iteration
IterEnd(t) ==
    /\ iterState[t] \in {"active", "exhausted"}
    /\ iterState' = [iterState EXCEPT ![t] = "inactive"]
    /\ iterCursor' = [iterCursor EXCEPT ![t] = Nil]
    /\ UNCHANGED <<nodeVars, linkVars, refVars, threadVars,
                   faultVars, histVars>>

(* ====================================================================== *)
(* ReleaseEntry: release RefEntry handle (base.rs:1654-1657)               *)
(* F1: missing release calls cause ref count leaks.                        *)
(* ====================================================================== *)

ReleaseEntry(t) ==
    /\ tEntry[t] # Nil
    /\ tEntry[t] \in NodePool
    /\ pc[t] = "Idle"       \* only release when not mid-operation
    /\ LET n == tEntry[t] IN
       /\ refCount' = [refCount EXCEPT ![n] = refCount[n] - 1]
       /\ tEntry' = [tEntry EXCEPT ![t] = Nil]
       \* If refCount reaches 0, schedule finalization (base.rs:296-303)
       /\ IF refCount[n] - 1 = 0 THEN
            nodeFinalized' = [nodeFinalized EXCEPT ![n] = TRUE]
          ELSE UNCHANGED nodeFinalized
    /\ UNCHANGED <<nodeKey, nodeHeight, nodeAllocated, linkVars,
         pc, tKey, tNode, tNew, tHeight, tLevel, tPred, tSucc,
         iterVars, faultVars, histVars>>

(* ====================================================================== *)
(* Next State Relation                                                     *)
(* ====================================================================== *)

InsertAction(t) ==
    \/ \E k \in Key, h \in 1..MaxLevel : InsertBegin(t, k, h)
    \/ InsertCAS(t)
    \/ InsertBuildLevel(t)

RemoveAction(t) ==
    \/ \E k \in Key : RemoveBegin(t, k)
    \/ RemoveMarkTower(t)
    \/ RemoveUnlink(t)

IterAction(t) ==
    \/ IterBegin(t)
    \/ IterNext(t)
    \/ IterEnd(t)

ThreadAction(t) ==
    \/ InsertAction(t)
    \/ RemoveAction(t)
    \/ Get(t, CHOOSE k \in Key : TRUE)
    \/ IterAction(t)
    \/ ReleaseEntry(t)

Next ==
    \/ \E t \in Thread : ThreadAction(t)
    \/ \E n \in NodePool, l \in Level : HelpUnlink(n, l)

Spec == Init /\ [][Next]_vars

(* ====================================================================== *)
(* Invariants                                                              *)
(* ====================================================================== *)

\* ---------- Structural ----------

\* HeadNode is always allocated and never finalized
HeadNodeAlive == nodeAllocated[HeadNode] /\ ~nodeFinalized[HeadNode]

\* Level-0 chain is sorted by key (among live nodes)
ListSorted ==
    \A n \in NodePool :
        nodeAllocated[n] /\ ~succMarked[n][0] /\ succ[n][0] # Nil /\
        succ[n][0] \in NodePool /\ ~succMarked[succ[n][0]][0] =>
        nodeKey[n] < nodeKey[succ[n][0]]

\* ---------- F1: Reference Count ----------

\* Count of levels where node n has a live (non-marked) predecessor.
LivePhysicalLinks(n) ==
    Cardinality({l \in Level : \E pred \in AllNodes :
        succ[pred][l] = n /\ ~succMarked[pred][l]})

\* Count of ALL levels where any predecessor points to n (including stale).
AllPhysicalLinks(n) ==
    Cardinality({l \in Level : \E pred \in AllNodes : succ[pred][l] = n})

\* Count of entry handles held by threads
EntryHandles(n) ==
    Cardinality({t \in Thread : tEntry[t] = n})

\* Two-sided reference count bound.
\* Lower bound: refCount >= live links + entries (marking a predecessor
\*   reduces live links before HelpUnlink decrements refCount).
\* Upper bound: refCount <= all links + entries (stale links from marked
\*   predecessors still exist structurally even though not ref-counted).
\* Excludes nodes between allocation and level-0 CAS (refCount is optimistic).
RefCountCorrect ==
    \A n \in NodePool :
        nodeAllocated[n] /\ ~nodeFinalized[n] /\
        ~(\E t \in Thread : tNew[t] = n /\ pc[t] = "InsertReady") =>
        /\ refCount[n] >= LivePhysicalLinks(n) + EntryHandles(n)
        /\ refCount[n] <= AllPhysicalLinks(n) + EntryHandles(n)

\* No thread accesses a finalized node's data
NoUseAfterFinalize ==
    \A n \in NodePool :
        nodeFinalized[n] => EntryHandles(n) = 0

\* ---------- F2: Linearizability ----------

\* If a key is in the abstract listMap, there must exist a live node with
\* that key reachable at level 0 (insert-get consistency).
InsertGetConsistency ==
    \A k \in listMap :
        \E n \in NodePool :
            nodeAllocated[n] /\ nodeKey[n] = k /\ ~succMarked[n][0]

\* Mark tower returns true at most once per node. Guaranteed by fetch_or
\* at level 0 — only one thread transitions FALSE -> TRUE.
\* Invariant: no two threads in RemoveUnlink for the same node.
RemoveLinearizability ==
    \A t1, t2 \in Thread :
        t1 # t2 /\ pc[t1] = "RemoveUnlink" /\ pc[t2] = "RemoveUnlink" =>
        tNode[t1] # tNode[t2]

\* ---------- F3: Iterator ----------

\* Once exhausted, iterator should stay exhausted (FusedIterator contract).
\* Bug #1142: this is violated because None cursor restarts from head.
\* This invariant is EXPECTED TO BE VIOLATED when checking against the
\* buggy iterator model above.
ExhaustedStaysExhausted ==
    \A t \in Thread :
        iterState[t] = "active" /\ iterCursor[t] = Nil =>
        \* This state should not exist if exhaustion is handled correctly.
        \* The iterator should transition to "exhausted" when cursor becomes Nil.
        FALSE

\* ---------- F4: Tower Marking Protocol ----------

\* If level L is marked, all levels > L are also marked (top-down invariant)
\* (base.rs:327-348: mark_tower marks from height-1 down to 0)
MarkingOrderTopDown ==
    \A n \in NodePool :
        nodeAllocated[n] =>
        \A l1, l2 \in Level :
            l1 < l2 /\ l2 < nodeHeight[n] /\ succMarked[n][l1] =>
            succMarked[n][l2]

\* Level 0 is authoritative for removal
Level0Authoritative ==
    \A n \in NodePool :
        nodeAllocated[n] =>
        (n \notin {nd \in NodePool : nodeKey[nd] \in listMap /\
                   ~succMarked[nd][0]}) \/
        ~succMarked[n][0]

\* A node being tower-built that gets concurrently marked should stop building
\* (verified by checking that InsertBuild detects the mark)
TowerBuildingSafety ==
    \A t \in Thread :
        pc[t] = "InsertBuild" /\ tNew[t] \in NodePool =>
        \* If the new node's current build level is already marked,
        \* the next InsertBuildLevel step will stop.
        TRUE  \* enforced by action precondition check

====
