---- MODULE MC_Family3 ----
EXTENDS base

SpoofSenders == {"X", "Y"}
F3Slots == 0..1

F3Next ==
    \/ \E rep \in Servers, from \in SpoofSenders, slot \in F3Slots :
        Handle2B(rep, from, slot, ballot[rep])
    \/ \E rep \in Servers, slot \in F3Slots :
        Succeed(rep, slot)

F3Spec == Init /\ [][F3Next]_vars

=============================================================================
