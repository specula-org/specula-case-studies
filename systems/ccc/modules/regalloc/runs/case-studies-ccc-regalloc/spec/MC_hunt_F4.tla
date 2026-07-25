---- MODULE MC_hunt_F4 ----
\* Tier-2 packer slot collision on under-approximated interval (Family 2, F4).
EXTENDS MC

BlockOfPointF4Op == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0 @@ 3 :> 0)
BlockSuccsF4Op   == (0 :> {})
TrueDefF4Op      == (1 :> 0 @@ 2 :> 2)
TrueUsesF4Op     == (1 :> {3} @@ 2 :> {3})
AsmHasOperandsF4Op == << >>
AsmClobbersF4Op    == << >>
IsRecognizedReturnsTwiceF4Op == (1 :> FALSE)
PriorityF4Op     == (1 :> 1 @@ 2 :> 1)

====
