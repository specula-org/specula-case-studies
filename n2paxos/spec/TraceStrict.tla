---- MODULE TraceStrict ----
EXTENDS Trace

\* Strict interpretation of Succeed: quorum reached AND local payload already known.
StrictSucceed(rep, slot) ==
    /\ status[rep] = NORMAL
    /\ VotesAt(rep, slot) >= Majority
    /\ HasCmdAt(rep, slot)
    /\ phases' = SetPhase(rep, slot, COMMIT)
    /\ UNCHANGED <<ballot, cballot, status, isLeader, lastCmdSlot,
                  cmdAt, slotOfCmd, clientSeen, proposalSeen,
                  beginBallots, votedSends, votes, delivered, receiveSuccesses,
                  proposalFromClient, proposalFromLearned, descMeta,
                  successEmits, deliverQueued, batch2ASeen, batch2BSeen>>

SucceedLoggedStrict ==
    /\ IsReplicaEvent("Succeed")
    /\ StrictSucceed(ev.nid, ev.slot)
    /\ StepToNextTrace

TraceNextStrict ==
    /\ l <= Len(TraceLog)
    /\ (ClientRequestLogged
        \/ ClientSubmitLogged
        \/ ClientReceiveSuccessLogged
        \/ ProposeLogged
        \/ SendBeginBallotLogged
        \/ ReceiveBeginBallotLogged
        \/ SendVotedLogged
        \/ ReceiveVotedLogged
        \/ SucceedLoggedStrict
        \/ SendSuccessLogged
        \/ SilentDeliverForReceiveSuccess
        \/ ReceiveSuccessLogged
        \/ SkipUnknownEvent)

TraceSpecStrict == TraceInit /\ [][TraceNextStrict]_<<l, vars>>

TraceMatchedStrict ==
    [](l <= Len(TraceLog) => [](TLCGet("queue") = 1 \/ l > Len(TraceLog)))

=============================================================================
