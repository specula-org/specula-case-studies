---- MODULE MC_hunt_F3 ----
\* Dataflow cap hit under non-convergent CFG (Family 1, F3).
EXTENDS MC

BlockOfPointF3Op == (0 :> 0 @@ 1 :> 0 @@ 2 :> 1)
BlockSuccsF3Op   == (0 :> {1} @@ 1 :> {0})
TrueDefF3Op      == (1 :> 0 @@ 2 :> 1)
TrueUsesF3Op     == (1 :> {2} @@ 2 :> {2})
AsmHasOperandsF3Op == << >>
AsmClobbersF3Op    == << >>
IsRecognizedReturnsTwiceF3Op == << >>
PriorityF3Op     == (1 :> 1 @@ 2 :> 1)

====
