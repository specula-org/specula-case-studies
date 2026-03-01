---- MODULE MC ----
EXTENDS base, TLC

CONSTANTS MaxClientReq, MaxReceive2B, MaxDeliver

VARIABLE faultCtr

faultVars == <<faultCtr>>

\* MC harness domains are intentionally much smaller than trace-validation domains.
\* This keeps TLC exploration tractable while still exercising code-level paths.
MCSlots == 0..4
\* Include one sentinel plus a broader set of realistic client/seq ids.
MCCmds ==
    {[client |-> -1, seq |-> -42]}
    \cup {[client |-> c, seq |-> s] : c \in 0..2, s \in 0..2}
SpoofSenders == {"X", "Y"}

MCInit ==
    /\ Init
    /\ faultCtr = [clientReq |-> 0, recv2b |-> 0, deliver |-> 0]

MCHandleClientRequestBatch(targets, cmd) ==
    /\ faultCtr.clientReq < MaxClientReq
    /\ HandleClientRequestBatch(targets, cmd)
    /\ faultCtr' = [faultCtr EXCEPT !.clientReq = @ + 1]

MCHandle2B(rep, from, slot, b) ==
    /\ faultCtr.recv2b < MaxReceive2B
    /\ Handle2B(rep, from, slot, b)
    /\ faultCtr' = [faultCtr EXCEPT !.recv2b = @ + 1]

MCDeliverChainStep(rep, slot) ==
    /\ faultCtr.deliver < MaxDeliver
    /\ DeliverChainStep(rep, slot)
    /\ faultCtr' = [faultCtr EXCEPT !.deliver = @ + 1]

MCUnbounded(a) ==
    /\ a
    /\ UNCHANGED faultVars

MCNext ==
    \/ \E cmd \in MCCmds :
        /\ ~HasClientSeen(Leader0, cmd)
        /\ MCHandleClientRequestBatch(<<Leader0>>, cmd)
    \/ \E rep \in Servers, from \in Servers, slot \in MCSlots :
        /\ from # rep
        /\ MCHandle2B(rep, from, slot, ballot[rep])
    \/ \E rep \in Servers, from \in SpoofSenders, slot \in MCSlots :
        /\ MCHandle2B(rep, from, slot, ballot[rep])
    \/ \E rep \in Servers, slot \in MCSlots :
        /\ CanDeliver(rep, slot)
        /\ MCDeliverChainStep(rep, slot)
    \/ \E slot \in MCSlots, cmd \in MCCmds :
        MCUnbounded(HandlePropose(Leader0, slot, cmd))
    \/ \E slot \in MCSlots :
        /\ HasCmdAt(Leader0, slot)
        /\ RC(Leader0, slot, CmdAtSlot(Leader0, slot).cmd) \notin beginBallots
        /\ MCUnbounded(SendBeginBallot(Leader0, slot, CmdAtSlot(Leader0, slot).cmd))
    \* A received 2A should carry a proposer's known cmd for that slot.
    \/ \E rep \in Servers, from \in Servers, slot \in MCSlots :
        MCUnbounded(
            /\ HasCmdAt(from, slot)
            /\ ~HasCmdAt(rep, slot) \/ CmdAtSlot(rep, slot).cmd # CmdAtSlot(from, slot).cmd
            /\ Handle2A(rep, from, slot, CmdAtSlot(from, slot).cmd, ballot[rep]))
    \/ \E rep \in Servers, slot \in MCSlots :
        /\ HasCmdAt(rep, slot)
        /\ RC(rep, slot, CmdAtSlot(rep, slot).cmd) \notin votedSends
        /\ MCUnbounded(SendVoted(rep, slot, CmdAtSlot(rep, slot).cmd, ballot[rep]))
    \/ \E rep \in Servers, slot \in MCSlots :
        /\ VotesAt(rep, slot) >= Majority
        /\ PhaseAt(rep, slot) # COMMIT
        /\ MCUnbounded(Succeed(rep, slot))
    \/ \E rep \in Servers, slot \in MCSlots :
        /\ PhaseAt(rep, slot) = COMMIT
        /\ ~HasDelivered(rep, slot)
        /\ MCUnbounded(SendSuccess(rep, slot))
    \/ \E rep \in Servers, slot \in MCSlots :
        /\ HasDelivered(rep, slot)
        /\ HasCmdAt(rep, slot)
        /\ RC(rep, slot, CmdAtSlot(rep, slot).cmd) \notin receiveSuccesses
        /\ MCUnbounded(ReceiveSuccess(rep, slot, CmdAtSlot(rep, slot).cmd))

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

MCTypeOK ==
    /\ TypeOK
    /\ faultCtr \in [clientReq : Int, recv2b : Int, deliver : Int]

MCView == <<ballot, status, phases, delivered, slotOfCmd>>

=============================================================================
