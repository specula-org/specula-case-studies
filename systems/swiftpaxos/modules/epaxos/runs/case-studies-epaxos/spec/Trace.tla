---- MODULE Trace ----
EXTENDS base, Json, IOUtils, TLC, Sequences

JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON ELSE "../artifact/epaxos/traces/trace.ndjson"

OriginTraceLog == SelectSeq(ndJsonDeserialize(JsonFile), LAMBDA x: "event" \in DOMAIN x)
TraceLog == TLCEval(IF "MAX_TRACE" \in DOMAIN IOEnv THEN SubSeq(OriginTraceLog, 1, atoi(IOEnv.MAX_TRACE)) ELSE OriginTraceLog)

VARIABLE l

traceVars == <<vars, l>>

Logline == TraceLog[l]
LoglineIs(name) == /\ l <= Len(TraceLog) /\ Logline.event.name = name
StepTrace == l' = l + 1
HasField(obj, key) == key \in DOMAIN obj

AbsInt(x) == IF x < 0 THEN -x ELSE x
NormReplicaFromString(s) == (AbsInt(atoi(s)) % Cardinality(Replicas)) + 1
NormReplicaFromInt(x) == (AbsInt(x) % Cardinality(Replicas)) + 1
NormClientFromInt(x) == (AbsInt(x) % Cardinality(Clients)) + 1
NormKeyFromInt(x) == (AbsInt(x) % Cardinality(Keys)) + 1
NormInstanceFromInt(x) == AbsInt(x) % (MaxInstance + 1)
NormCmdId(clientRaw, seqRaw) == (((AbsInt(clientRaw) % MaxCmdId) + (AbsInt(seqRaw) % MaxCmdId)) % MaxCmdId) + 1

IsClientModule == /\ "module" \in DOMAIN Logline.event /\ Logline.event.module = "client"
IsReplicaModule == /\ "module" \in DOMAIN Logline.event /\ Logline.event.module = "epaxos_replica"
HasIID == /\ HasField(Logline.event, "iid")
          /\ HasField(Logline.event.iid, "replica")
          /\ HasField(Logline.event.iid, "instance")
HasNid == HasField(Logline.event, "nid")
HasStateStatus == /\ HasField(Logline.event, "state")
                  /\ HasField(Logline.event.state, "status")
IsBroadcastPhase == /\ HasField(Logline.event, "phase")
                    /\ Logline.event.phase = "broadcast"
EventNid == atoi(Logline.event.nid)
EventRR == Logline.event.iid.replica
EventII == Logline.event.iid.instance
HasRepresentableNid == HasNid /\ EventNid \in Replicas
HasRepresentableIID == HasIID /\ EventRR \in Replicas /\ EventII \in Instances
TraceNoOp == /\ UNCHANGED vars /\ StepTrace
StatusMatches(n, rr, ii) == ~HasStateStatus \/ inst'[n][rr][ii].status = Logline.event.state.status
PreAcceptMsgMatches ==
  \E m \in msgs :
    /\ m.typ = "PreAccept"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
HasPreAcceptReplyMsg ==
  \E m \in msgs :
    /\ m.typ = "PreAcceptReply"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
PreAcceptReplyStatusMatches ==
  ~HasStateStatus
  \/ (\E m \in msgs :
        /\ m.typ = "PreAcceptReply"
        /\ m.to = EventNid
        /\ m.rr = EventRR
        /\ m.ii = EventII
        /\ m.status = Logline.event.state.status)
CommitMsgMatches ==
  \E m \in msgs :
    /\ m.typ = "Commit"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
HasAcceptMsg ==
  \E m \in msgs :
    /\ m.typ = "Accept"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
HasAcceptReplyMsg ==
  \E m \in msgs :
    /\ m.typ = "AcceptReply"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
HasPrepareMsg ==
  \E m \in msgs :
    /\ m.typ = "Prepare"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
HasPrepareReplyMsg ==
  \E m \in msgs :
    /\ m.typ = "PrepareReply"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
PreAcceptMsgConsumed ==
  \E m \in msgs :
    /\ m.typ = "PreAccept"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
    /\ m \notin msgs'
PreAcceptReplyMsgConsumed ==
  \E m \in msgs :
    /\ m.typ = "PreAcceptReply"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
    /\ m \notin msgs'
CommitMsgConsumed ==
  \E m \in msgs :
    /\ m.typ = "Commit"
    /\ m.to = EventNid
    /\ m.rr = EventRR
    /\ m.ii = EventII
    /\ m \notin msgs'
FastPathSlotMatches == Slot(EventNid, EventRR, EventII) \in pendingFastPath
ExecuteSlotEnabled(n, rr, ii) ==
  /\ n \in members
  /\ ~crashed[n]
  /\ inst[n][rr][ii].status = "COMMITTED"
  /\ \A q \in Replicas : inst[n][rr][ii].deps[q] <= committedUpTo[n][q]
  /\ \A rr2 \in Replicas, ii2 \in Instances :
       /\ inst[n][rr2][ii2].status = "COMMITTED"
       /\ ~ExecutedAt(n, rr2, ii2)
       /\ BatchConflict(inst[n][rr2][ii2].cmds, inst[n][rr][ii].cmds)
       => ~SlotLess(Slot(n, rr2, ii2), Slot(n, rr, ii))
PreAcceptAligned == /\ PreAcceptMsgMatches /\ PreAccept /\ PreAcceptMsgConsumed /\ StatusMatches(EventNid, EventRR, EventII)
PreAcceptOKAligned == /\ PreAcceptOK /\ PreAcceptReplyMsgConsumed /\ PreAcceptReplyStatusMatches
FastPathCommitAligned == /\ FastPathSlotMatches /\ FastPathCommit /\ StatusMatches(EventNid, EventRR, EventII)
CommitAligned == /\ CommitMsgMatches /\ Commit /\ CommitMsgConsumed /\ StatusMatches(EventNid, EventRR, EventII)
ExecuteAligned == /\ ExecuteSlotEnabled(EventNid, EventRR, EventII) /\ Execute /\ StatusMatches(EventNid, EventRR, EventII)
PreAcceptOKNoMsgJustified ==
  /\ HasField(Logline.event, "preAcceptOKs")
  /\ \/ lb[EventNid][EventRR][EventII].preAcceptOKs + 1 >= Logline.event.preAcceptOKs
     \/ inst[EventNid][EventRR][EventII].status \in {"COMMITTED", "EXECUTED"}
FastPathNoSlotJustified ==
  /\ HasField(Logline.event, "preAcceptOKs")
  /\ HasStateStatus
  /\ Logline.event.state.status = "COMMITTED"
CommitNoMsgJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status = "COMMITTED"
CommitDisabledNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status = "COMMITTED"
ExecuteNoSlotJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status = "EXECUTED"
PreAcceptNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"PREACCEPTED", "PREACCEPTED_EQ"}
AcceptNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}
AcceptOKNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}
PrepareNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"NONE", "PREACCEPTED", "PREACCEPTED_EQ", "ACCEPTED", "COMMITTED", "EXECUTED"}
PrepareOKNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"NONE", "PREACCEPTED", "PREACCEPTED_EQ", "ACCEPTED", "COMMITTED", "EXECUTED"}
RecoveryAcceptNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}
JoinNoOpJustified ==
  /\ HasStateStatus
  /\ Logline.event.state.status \in {"NONE", "PREACCEPTED", "PREACCEPTED_EQ", "ACCEPTED", "COMMITTED", "EXECUTED"}

TraceInit == /\ Init /\ l = 1

TraceClientRequest ==
  /\ LoglineIs("ClientRequest")
  /\ \/ /\ IsClientModule
        /\ ClientSubmit
     \/ /\ IsReplicaModule
        /\ \/ /\ HasRepresentableNid
              /\ HasRepresentableIID
              /\ HasField(Logline.event, "command")
              /\ HasField(Logline.event.command, "key")
              /\ HasField(Logline.event.command, "op")
              /\ HasField(Logline.event, "clientId")
              /\ LET n == EventNid
                     c == NormClientFromInt(Logline.event.clientId)
                     id == NormCmdId(Logline.event.clientId, Logline.event.iid.instance)
                     op == Logline.event.command.op
                     k == NormKeyFromInt(Logline.event.command.key)
                     i == EventII
                 IN ClientRequestOn(n, c, id, op, k, i)
           \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
              /\ TraceNoOp
  /\ StepTrace
TraceClientSubmit == /\ LoglineIs("ClientSubmit") /\ ClientSubmit /\ StepTrace
TracePreAccept ==
  /\ LoglineIs("PreAccept")
  /\ \/ /\ IsBroadcastPhase
        /\ TraceNoOp
     \/ /\ ~IsBroadcastPhase
        /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ PreAcceptMsgMatches
              /\ PreAcceptAligned
              /\ StepTrace
           \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ PreAcceptMsgMatches
              /\ ~ENABLED PreAcceptAligned
              /\ PreAcceptNoOpJustified
              /\ TraceNoOp
           \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
              /\ TraceNoOp
TracePreAcceptOK ==
  /\ LoglineIs("PreAcceptOK")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasPreAcceptReplyMsg
        /\ PreAcceptOKAligned
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasPreAcceptReplyMsg
        /\ ~ENABLED PreAcceptOKAligned
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~HasPreAcceptReplyMsg
        /\ PreAcceptOKNoMsgJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TraceFastPathCommit ==
  /\ LoglineIs("FastPathCommit")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ FastPathSlotMatches
        /\ FastPathCommitAligned
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ FastPathSlotMatches
        /\ ~ENABLED FastPathCommitAligned
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~FastPathSlotMatches
        /\ FastPathNoSlotJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TraceAccept ==
  /\ LoglineIs("Accept")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasAcceptMsg
        /\ Accept
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasAcceptMsg
        /\ ~ENABLED Accept
        /\ AcceptNoOpJustified
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~HasAcceptMsg
        /\ AcceptNoOpJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TraceAcceptOK ==
  /\ LoglineIs("AcceptOK")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasAcceptReplyMsg
        /\ AcceptOK
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasAcceptReplyMsg
        /\ ~ENABLED AcceptOK
        /\ AcceptOKNoOpJustified
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~HasAcceptReplyMsg
        /\ AcceptOKNoOpJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TraceCommit ==
  /\ LoglineIs("Commit")
  /\ \/ /\ IsBroadcastPhase
        /\ TraceNoOp
     \/ /\ ~IsBroadcastPhase
        /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ CommitMsgMatches
              /\ CommitAligned
              /\ StepTrace
           \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ CommitMsgMatches
              /\ ~ENABLED CommitAligned
              /\ CommitDisabledNoOpJustified
              /\ TraceNoOp
           \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~CommitMsgMatches
              /\ CommitNoMsgJustified
              /\ TraceNoOp
           \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
              /\ TraceNoOp
TraceExecute ==
  /\ LoglineIs("Execute")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ExecuteSlotEnabled(EventNid, EventRR, EventII)
        /\ ExecuteAligned
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ExecuteSlotEnabled(EventNid, EventRR, EventII)
        /\ ~ENABLED ExecuteAligned
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~ExecuteSlotEnabled(EventNid, EventRR, EventII)
        /\ ExecuteNoSlotJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TracePrepare ==
  /\ LoglineIs("Prepare")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ Prepare /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~ENABLED Prepare
        /\ PrepareNoOpJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TracePrepareOK ==
  /\ LoglineIs("PrepareOK")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasPrepareReplyMsg
        /\ PrepareOK
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasPrepareReplyMsg
        /\ ~ENABLED PrepareOK
        /\ PrepareOKNoOpJustified
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~HasPrepareReplyMsg
        /\ PrepareOKNoOpJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TraceRecoveryAccept ==
  /\ LoglineIs("RecoveryAccept")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ RecoveryAccept /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~ENABLED RecoveryAccept
        /\ RecoveryAcceptNoOpJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp
TraceJoin ==
  /\ LoglineIs("Join")
  /\ \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasPrepareMsg
        /\ Join
        /\ StepTrace
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ HasPrepareMsg
        /\ ~ENABLED Join
        /\ JoinNoOpJustified
        /\ TraceNoOp
     \/ /\ HasRepresentableNid /\ HasRepresentableIID /\ ~HasPrepareMsg
        /\ JoinNoOpJustified
        /\ TraceNoOp
     \/ /\ ~(HasRepresentableNid /\ HasRepresentableIID)
        /\ TraceNoOp

Silent == /\ l > Len(TraceLog) /\ UNCHANGED traceVars

TraceNext ==
  /\ IF l <= Len(TraceLog)
     THEN \/ TraceClientRequest
          \/ TraceClientSubmit
          \/ TracePreAccept
          \/ TracePreAcceptOK
          \/ TraceFastPathCommit
          \/ TraceAccept
          \/ TraceAcceptOK
          \/ TraceCommit
          \/ TraceExecute
          \/ TracePrepare
          \/ TracePrepareOK
          \/ TraceRecoveryAccept
          \/ TraceJoin
     ELSE Silent

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
TraceDepth == IF "MAX_DEPTH" \in DOMAIN IOEnv THEN atoi(IOEnv.MAX_DEPTH) ELSE 1000
DepthBound == l <= TraceDepth

====
