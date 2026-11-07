---- MODULE Var ----
EXTENDS Base
UseS == LossyS
UseOp == LossyOp(F)
UseOpLossy == LossyOp(F) /\ z = z
====
