---- MODULE MC_hunt_F1 ----
\* Asm-no-operands caller-saved clobber drop (Family 1, F1).
EXTENDS MC

BlockOfPointF1Op == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0)
BlockSuccsF1Op   == (0 :> {})
TrueDefF1Op      == (1 :> 0)
TrueUsesF1Op     == (1 :> {2})
AsmHasOperandsF1Op == (1 :> FALSE)
AsmClobbersF1Op    == (1 :> {20})
IsRecognizedReturnsTwiceF1Op == << >>
PriorityF1Op     == (1 :> 1)

====
