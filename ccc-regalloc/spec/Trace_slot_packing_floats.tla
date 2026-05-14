---- MODULE Trace_slot_packing_floats ----
\* Auto-derived per-scenario wrapper.
EXTENDS Trace

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0 @@ 3 :> 0 @@ 4 :> 0 @@ 5 :> 1 @@ 6 :> 1 @@ 7 :> 1 @@ 8 :> 1)
BlockSuccsOp   == (0 :> {1} @@ 1 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 1 @@ 3 :> 2 @@ 4 :> 3 @@ 5 :> 5 @@ 6 :> 6 @@ 7 :> 7)
TrueUsesOp     == (1 :> {5} @@ 2 :> {5} @@ 3 :> {6} @@ 4 :> {6} @@ 5 :> {7} @@ 6 :> {7} @@ 7 :> {8})
AsmHasOperandsOp == << >>
AsmClobbersOp    == << >>
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 1 @@ 2 :> 1 @@ 3 :> 1 @@ 4 :> 1 @@ 5 :> 1 @@ 6 :> 1 @@ 7 :> 1)
SlotsOp == {-32,-24,-16,-8,100,104,108,112,116,120,124}

====
