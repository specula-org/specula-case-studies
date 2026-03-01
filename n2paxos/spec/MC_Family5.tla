---- MODULE MC_Family5 ----
EXTENDS base

F5Slots == 0..2
F5Cmds == {
    [client |-> 0, seq |-> 0],
    [client |-> 1, seq |-> 0]
}

\* Family 5 focus: batch receive interleavings should not allow commit on a slot
\* with no learned command yet.
CommitRequiresCommandKnown ==
    \A p \in phases : p.phase = COMMIT => HasCmdAt(p.rep, p.slot)

F5Next ==
    \/ \E rep \in Servers, from \in Servers, slot \in F5Slots :
        Handle2BFromBatch(rep, from, slot, ballot[rep])
    \/ \E rep \in Servers, slot \in F5Slots :
        Succeed(rep, slot)
    \/ \E rep \in Servers, from \in Servers, slot \in F5Slots, cmd \in F5Cmds :
        Handle2AFromBatch(rep, from, slot, cmd, ballot[rep])
    \/ \E rep \in Servers, slot \in F5Slots :
        EmitSuccess(rep, slot)
    \/ \E rep \in Servers, slot \in F5Slots :
        EnterDeliver(rep, slot)
    \/ \E rep \in Servers, slot \in F5Slots :
        DeliverChainStep(rep, slot)

F5Spec == Init /\ [][F5Next]_vars

=============================================================================
