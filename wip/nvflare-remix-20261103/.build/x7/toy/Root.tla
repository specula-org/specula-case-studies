---- MODULE Root ----
EXTENDS Base, TLC
V == INSTANCE Var
VN == INSTANCE Var WITH F <- {}
Init == z = 0
Next == UNCHANGED z
Inv == PrintT(<<"C", V!UseS, VN!UseS, VN!LossyS, VN!UseOp, VN!UseOpLossy>>)
====
