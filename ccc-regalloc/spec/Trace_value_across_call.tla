---- MODULE Trace_value_across_call ----
\* Auto-derived per-scenario wrapper.
EXTENDS Trace

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0 @@ 3 :> 0)
BlockSuccsOp   == (0 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 2)
TrueUsesOp     == (1 :> {2} @@ 2 :> {3})
AsmHasOperandsOp == << >>
AsmClobbersOp    == << >>
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 2 @@ 2 :> 1)

====
