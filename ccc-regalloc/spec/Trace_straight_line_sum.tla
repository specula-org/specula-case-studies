---- MODULE Trace_straight_line_sum ----
\* Auto-derived per-scenario wrapper.
EXTENDS Trace

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0)
BlockSuccsOp   == (0 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 1)
TrueUsesOp     == (1 :> {1} @@ 2 :> {2})
AsmHasOperandsOp == << >>
AsmClobbersOp    == << >>
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 1 @@ 2 :> 1)

====
