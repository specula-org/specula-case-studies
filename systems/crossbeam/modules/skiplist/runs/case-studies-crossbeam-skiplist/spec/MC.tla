---- MODULE MC ----
(***************************************************************************)
(* Model Checking wrapper for crossbeam-skiplist base spec.                *)
(*                                                                         *)
(* Counter-bounds non-deterministic actions (insert, remove, help_unlink). *)
(* Reactive actions (CAS, mark, build, unlink) pass through unbounded.     *)
(*                                                                         *)
(* Hunting configs override MarkBeforeCASFlag to target F2 bugs.           *)
(***************************************************************************)

EXTENDS base

(* ====================================================================== *)
(* MC Constants                                                            *)
(* ====================================================================== *)

CONSTANTS
    MaxInsertLimit,         \* Counter bound for InsertBegin
    MaxRemoveLimit,         \* Counter bound for RemoveBegin
    MaxHelpUnlinkLimit,     \* Counter bound for HelpUnlink
    MarkBeforeCASFlag       \* Override: TRUE to reproduce bug #1023 (F2)

(* ====================================================================== *)
(* MC Variables                                                            *)
(* ====================================================================== *)

VARIABLES
    insertCount,            \* Counter: InsertBegin invocations
    removeCount,            \* Counter: RemoveBegin invocations
    helpUnlinkCount         \* Counter: HelpUnlink invocations

mcVars  == <<insertCount, removeCount, helpUnlinkCount>>
allVars == <<vars, mcVars>>

(* ====================================================================== *)
(* MC Init                                                                 *)
(* ====================================================================== *)

MCInit ==
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
    \* Fault injection from MC constant
    /\ markBeforeCAS = MarkBeforeCASFlag
    /\ listMap       = {}
    \* MC counters
    /\ insertCount     = 0
    /\ removeCount     = 0
    /\ helpUnlinkCount = 0

(* ====================================================================== *)
(* Counter-Bounded Actions                                                 *)
(* ====================================================================== *)

MCInsertBegin(t, k, h) ==
    /\ insertCount < MaxInsertLimit
    /\ InsertBegin(t, k, h)
    /\ insertCount' = insertCount + 1
    /\ UNCHANGED <<removeCount, helpUnlinkCount>>

MCRemoveBegin(t, k) ==
    /\ removeCount < MaxRemoveLimit
    /\ RemoveBegin(t, k)
    /\ removeCount' = removeCount + 1
    /\ UNCHANGED <<insertCount, helpUnlinkCount>>

MCHelpUnlink(n, l) ==
    /\ helpUnlinkCount < MaxHelpUnlinkLimit
    /\ HelpUnlink(n, l)
    /\ helpUnlinkCount' = helpUnlinkCount + 1
    /\ UNCHANGED <<insertCount, removeCount>>

(* ====================================================================== *)
(* Unbounded Actions (reactive / deterministic)                            *)
(* ====================================================================== *)

MCInsertCAS(t)        == InsertCAS(t)        /\ UNCHANGED mcVars
MCInsertBuildLevel(t) == InsertBuildLevel(t)  /\ UNCHANGED mcVars
MCRemoveMarkTower(t)  == RemoveMarkTower(t)   /\ UNCHANGED mcVars
MCRemoveUnlink(t)     == RemoveUnlink(t)       /\ UNCHANGED mcVars
MCGet(t, k)           == Get(t, k)             /\ UNCHANGED mcVars
MCIterBegin(t)        == IterBegin(t)          /\ UNCHANGED mcVars
MCIterNext(t)         == IterNext(t)           /\ UNCHANGED mcVars
MCIterEnd(t)          == IterEnd(t)            /\ UNCHANGED mcVars
MCReleaseEntry(t)     == ReleaseEntry(t)       /\ UNCHANGED mcVars

(* ====================================================================== *)
(* MC Next                                                                 *)
(* ====================================================================== *)

MCInsertAction(t) ==
    \/ \E k \in Key, h \in 1..MaxLevel : MCInsertBegin(t, k, h)
    \/ MCInsertCAS(t)
    \/ MCInsertBuildLevel(t)

MCRemoveAction(t) ==
    \/ \E k \in Key : MCRemoveBegin(t, k)
    \/ MCRemoveMarkTower(t)
    \/ MCRemoveUnlink(t)

MCIterAction(t) ==
    \/ MCIterBegin(t)
    \/ MCIterNext(t)
    \/ MCIterEnd(t)

MCThreadAction(t) ==
    \/ MCInsertAction(t)
    \/ MCRemoveAction(t)
    \/ MCGet(t, CHOOSE k \in Key : TRUE)
    \/ MCIterAction(t)
    \/ MCReleaseEntry(t)

MCNext ==
    \/ \E t \in Thread : MCThreadAction(t)
    \/ \E n \in NodePool, l \in Level : MCHelpUnlink(n, l)

MCSpec == MCInit /\ [][MCNext]_allVars

(* ====================================================================== *)
(* Symmetry                                                                *)
(* ====================================================================== *)

MCSymmetry == Permutations(Thread)

(* ====================================================================== *)
(* State Constraint                                                        *)
(* ====================================================================== *)

MCStateConstraint ==
    /\ insertCount     <= MaxInsertLimit
    /\ removeCount     <= MaxRemoveLimit
    /\ helpUnlinkCount <= MaxHelpUnlinkLimit

====
