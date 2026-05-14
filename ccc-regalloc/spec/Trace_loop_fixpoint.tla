---- MODULE Trace_loop_fixpoint ----
\* Auto-derived per-scenario wrapper.
EXTENDS Trace

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 1 @@ 3 :> 1 @@ 4 :> 2 @@ 5 :> 3)
BlockSuccsOp   == (0 :> {1} @@ 1 :> {2,3} @@ 2 :> {1} @@ 3 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 2)
TrueUsesOp     == (1 :> {2} @@ 2 :> {5})
AsmHasOperandsOp == << >>
AsmClobbersOp    == << >>
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 1 @@ 2 :> 2)

====
