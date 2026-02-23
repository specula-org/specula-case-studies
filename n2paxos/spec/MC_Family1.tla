---- MODULE MC_Family1 ----
EXTENDS base

F1Slots == 0..2
F1Cmds == {
    [client |-> 0, seq |-> 0],
    [client |-> 1, seq |-> 0]
}

\* Strict (paper-style) check: execution must not happen before commit.
StrictExecuteAfterCommit ==
    \A d \in delivered : PhaseAt(d.rep, d.slot) = COMMIT

F1Next ==
    \/ \E cmd \in F1Cmds :
        HandleClientRequestBatch(<<Leader0>>, cmd)
    \/ \E slot \in F1Slots, cmd \in F1Cmds :
        HandlePropose(Leader0, slot, cmd)
    \/ \E slot \in F1Slots, from \in Servers :
        Handle2B(Leader0, from, slot, ballot[Leader0])
    \/ \E slot \in F1Slots :
        Succeed(Leader0, slot)
    \/ \E slot \in F1Slots :
        EmitSuccess(Leader0, slot)
    \/ \E slot \in F1Slots :
        EnterDeliver(Leader0, slot)
    \/ \E slot \in F1Slots :
        DeliverChainStep(Leader0, slot)

F1Spec == Init /\ [][F1Next]_vars

=============================================================================
