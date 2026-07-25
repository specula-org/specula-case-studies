---- MODULE MC_hunt_F5 ----
\* Pool disjointness convention violation (Family 2, F5).
EXTENDS MC

BlockOfPointF5Op == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0)
BlockSuccsF5Op   == (0 :> {})
TrueDefF5Op      == (1 :> 0 @@ 2 :> 1)
TrueUsesF5Op     == (1 :> {2} @@ 2 :> {2})
AsmHasOperandsF5Op == << >>
AsmClobbersF5Op    == << >>
IsRecognizedReturnsTwiceF5Op == << >>
PriorityF5Op     == (1 :> 1 @@ 2 :> 1)

====
