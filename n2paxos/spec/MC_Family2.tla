---- MODULE MC_Family2 ----
EXTENDS base

F2Slots == 0..1
F2Cmds == {
    [client |-> 0, seq |-> 0],
    [client |-> 1, seq |-> 0]
}
Follower == "1"

\* If this fails, it demonstrates commit can exist without local proposal visibility
\* required by deliver path (clientSeen/propose dependency).
CommittedHasDeliverPayloadAtFollower ==
    \A slot \in F2Slots :
        (PhaseAt(Follower, slot) = COMMIT /\ HasCmdAt(Follower, slot))
            => HasDeliverPayload(Follower, slot)

F2Next ==
    \/ \E cmd \in F2Cmds :
        \* Single-target client dissemination adversary: leader-only visibility.
        HandleClientRequestBatch(<<Leader0>>, cmd)
    \/ \E slot \in F2Slots, cmd \in F2Cmds :
        HandlePropose(Leader0, slot, cmd)
    \/ \E slot \in F2Slots :
        /\ HasCmdAt(Leader0, slot)
        /\ Handle2A(Follower, Leader0, slot, CmdAtSlot(Leader0, slot).cmd, ballot[Follower])
    \/ \E slot \in F2Slots, from \in Servers :
        Handle2B(Follower, from, slot, ballot[Follower])
    \/ \E slot \in F2Slots :
        Succeed(Follower, slot)
    \/ \E slot \in F2Slots :
        EmitSuccess(Follower, slot)
    \/ \E slot \in F2Slots :
        EnterDeliver(Follower, slot)
    \/ \E slot \in F2Slots :
        DeliverChainStep(Follower, slot)

F2Spec == Init /\ [][F2Next]_vars

=============================================================================
