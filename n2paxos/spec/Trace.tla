---- MODULE Trace ----
EXTENDS base, Json, IOUtils, Sequences, TLC, FiniteSets

ASSUME TLCGet("config").mode = "bfs"

JsonFile ==
    IF "TRACE_PATH" \in DOMAIN IOEnv THEN IOEnv.TRACE_PATH ELSE "../artifact/n2paxos/traces/n2paxos/merged1.ndjson"

OriginTraceLog == SelectSeq(ndJsonDeserialize(JsonFile), LAMBDA l: "event" \in DOMAIN l)

TraceLog ==
    TLCEval(
        IF "MAX_TRACE" \in DOMAIN IOEnv
        THEN SubSeq(OriginTraceLog, 1, atoi(IOEnv.MAX_TRACE))
        ELSE OriginTraceLog)

ProgressStride == IF Len(TraceLog) < 100 THEN 1 ELSE Len(TraceLog) \div 100

VARIABLE l

logline == TraceLog[l]
ev == logline.event

CmdFromEvent(e) == [client |-> e.cmd.client, seq |-> e.cmd.seq]

UndeliveredPrefix(rep, slot) == {s \in 0..slot : ~HasDelivered(rep, s)}
FirstUndelivered(rep, slot) ==
    CHOOSE s \in UndeliveredPrefix(rep, slot) :
        \A t \in UndeliveredPrefix(rep, slot) : s <= t

StepToNextTrace ==
    /\ l' = l + 1
    /\ l % ProgressStride = 0 => PrintT(<<"trace-progress-%", (l * 100) \div Len(TraceLog)>>)

IsClientEvent(name) ==
    /\ "module" \in DOMAIN ev
    /\ "name" \in DOMAIN ev
    /\ ev.module = "client"
    /\ ev.name = name

IsReplicaEvent(name) ==
    /\ "module" \in DOMAIN ev
    /\ "name" \in DOMAIN ev
    /\ ev.module = "n2paxos_replica"
    /\ ev.name = name

ClientRequestLogged ==
    /\ IsClientEvent("ClientRequest")
    /\ "target" \in DOMAIN ev
    /\ HandleClientRequestBatch(ev.target, CmdFromEvent(ev))
    /\ StepToNextTrace

ClientSubmitLogged ==
    /\ IsClientEvent("ClientSubmit")
    /\ UNCHANGED vars
    /\ StepToNextTrace

ClientReceiveSuccessLogged ==
    /\ IsClientEvent("ReceiveSuccess")
    /\ UNCHANGED vars
    /\ StepToNextTrace

ProposeLogged ==
    /\ IsReplicaEvent("Propose")
    /\ HandlePropose(ev.nid, ev.slot, CmdFromEvent(ev))
    /\ StepToNextTrace

SendBeginBallotLogged ==
    /\ IsReplicaEvent("SendBeginBallot")
    /\ SendBeginBallot(ev.nid, ev.slot, CmdFromEvent(ev))
    /\ StepToNextTrace

ReceiveBeginBallotLogged ==
    /\ IsReplicaEvent("ReceiveBeginBallot")
    /\ Handle2A(ev.nid, ev.from, ev.slot, CmdFromEvent(ev), ev.state.ballot)
    /\ StepToNextTrace

SendVotedLogged ==
    /\ IsReplicaEvent("SendVoted")
    /\ SendVoted(ev.nid, ev.slot, CmdFromEvent(ev), ev.state.ballot)
    /\ StepToNextTrace

ReceiveVotedLogged ==
    /\ IsReplicaEvent("ReceiveVoted")
    /\ Handle2B(ev.nid, ev.from, ev.slot, ev.state.ballot)
    /\ StepToNextTrace

SucceedLogged ==
    /\ IsReplicaEvent("Succeed")
    /\ Succeed(ev.nid, ev.slot)
    /\ StepToNextTrace

SendSuccessLogged ==
    /\ IsReplicaEvent("SendSuccess")
    /\ EmitSuccess(ev.nid, ev.slot)
    /\ StepToNextTrace

ReceiveSuccessLogged ==
    /\ IsReplicaEvent("ReceiveSuccess")
    /\ ReceiveSuccess(ev.nid, ev.slot, CmdFromEvent(ev))
    /\ StepToNextTrace

SilentDeliverForReceiveSuccess ==
    /\ IsReplicaEvent("ReceiveSuccess")
    /\ ~HasDelivered(ev.nid, ev.slot)
    /\ UndeliveredPrefix(ev.nid, ev.slot) # {}
    /\ DeliverChainStep(ev.nid, FirstUndelivered(ev.nid, ev.slot))
    /\ UNCHANGED l

KnownEvent ==
    \/ IsClientEvent("ClientRequest")
    \/ IsClientEvent("ClientSubmit")
    \/ IsClientEvent("ReceiveSuccess")
    \/ IsReplicaEvent("Propose")
    \/ IsReplicaEvent("SendBeginBallot")
    \/ IsReplicaEvent("ReceiveBeginBallot")
    \/ IsReplicaEvent("SendVoted")
    \/ IsReplicaEvent("ReceiveVoted")
    \/ IsReplicaEvent("Succeed")
    \/ IsReplicaEvent("SendSuccess")
    \/ IsReplicaEvent("ReceiveSuccess")

SkipUnknownEvent ==
    /\ ~KnownEvent
    /\ UNCHANGED vars
    /\ StepToNextTrace

TraceInit ==
    /\ l = 1
    /\ Init

TraceNext ==
    /\ l <= Len(TraceLog)
    /\ (ClientRequestLogged
        \/ ClientSubmitLogged
        \/ ClientReceiveSuccessLogged
        \/ ProposeLogged
        \/ SendBeginBallotLogged
        \/ ReceiveBeginBallotLogged
        \/ SendVotedLogged
        \/ ReceiveVotedLogged
        \/ SucceedLogged
        \/ SendSuccessLogged
        \/ SilentDeliverForReceiveSuccess
        \/ ReceiveSuccessLogged
        \/ SkipUnknownEvent)

TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>>

TraceView == <<vars, l>>

ASSUME TLCGet("config").worker = 1

TraceMatched ==
    [](l <= Len(TraceLog) => [](TLCGet("queue") = 1 \/ l > Len(TraceLog)))

=============================================================================
