---- MODULE MC_hunt_F2 ----
\* Unrecognised returns-twice call (Family 1, F2).
EXTENDS MC

BlockOfPointF2Op == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0 @@ 3 :> 0)
BlockSuccsF2Op   == (0 :> {})
TrueDefF2Op      == (1 :> 0 @@ 2 :> 3)
TrueUsesF2Op     == (1 :> {2} @@ 2 :> {3})
AsmHasOperandsF2Op == << >>
AsmClobbersF2Op    == << >>
IsRecognizedReturnsTwiceF2Op == (2 :> FALSE)
PriorityF2Op     == (1 :> 1 @@ 2 :> 1)

====
