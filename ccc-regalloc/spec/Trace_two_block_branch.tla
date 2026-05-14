---- MODULE Trace_two_block_branch ----
\* Auto-derived per-scenario wrapper.
EXTENDS Trace

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0 @@ 3 :> 1 @@ 4 :> 1 @@ 5 :> 2)
BlockSuccsOp   == (0 :> {1,2} @@ 1 :> {} @@ 2 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 1 @@ 3 :> 3)
TrueUsesOp     == (1 :> {3} @@ 2 :> {5} @@ 3 :> {4})
AsmHasOperandsOp == << >>
AsmClobbersOp    == << >>
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 2 @@ 2 :> 2 @@ 3 :> 1)

====
