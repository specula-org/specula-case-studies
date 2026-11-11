------------------------------- MODULE Net_L -------------------------------
\* Group Net, LOSSY variant: up to LossBudget pending messages of lossy kinds
\* can be lost (cell send failure / connection drop). Writes: net_l, net.
EXTENDS Ports
VARIABLE net_l
LossBudget == IF "lossBudget3" \in Profile THEN 3 ELSE 1
LossyKinds == Kinds
Init == net_l = 0
\* @L Net.loss
Lose(k) ==
    /\ LossyIn(Faults, {net[k].msg.kind}) /\ net_l < LossBudget
    /\ ~net[k].lost /\ net[k].msg.kind \in LossyKinds
    /\ net' = [net EXCEPT ![k].lost = TRUE]
    /\ net_l' = net_l + 1
Next == \E k \in DOMAIN net : Lose(k)
=============================================================================
