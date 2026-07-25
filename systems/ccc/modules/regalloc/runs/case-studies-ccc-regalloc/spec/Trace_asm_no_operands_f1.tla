---- MODULE Trace_asm_no_operands_f1 ----
\* Auto-derived per-scenario wrapper.
EXTENDS Trace

BlockOfPointOp == (0 :> 0 @@ 1 :> 0 @@ 2 :> 0 @@ 3 :> 0)
BlockSuccsOp   == (0 :> {})
TrueDefOp      == (1 :> 0 @@ 2 :> 2)
TrueUsesOp     == (1 :> {2} @@ 2 :> {3})
AsmHasOperandsOp == (1 :> FALSE)
AsmClobbersOp    == (1 :> {10})
IsRecognizedReturnsTwiceOp == << >>
PriorityOp     == (1 :> 2 @@ 2 :> 1)

====
