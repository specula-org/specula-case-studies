---- MODULE Base ----
CONSTANT F
VARIABLE z
Lossy == "x" \in F
LossyS == z = z /\ "x" \in F
LossyOp(f) == "x" \in f
====
