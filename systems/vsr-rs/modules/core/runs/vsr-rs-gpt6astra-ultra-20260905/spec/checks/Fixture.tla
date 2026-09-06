----------------------------- MODULE Fixture -----------------------------
EXTENDS Trace
VARIABLES records, done
fv == <<vars,l,records,done>>
D(ev,t,k) == [event |-> ev, target |-> t, kind |-> k]
Script == <<
 D("ClientOnRequest",3,"Put"), D("ClientDrain",3,""),
 D("ReplicaOnMessage",0,"Request"), D("PersistView",0,""),
 D("ReleaseMessage",0,""), D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",1,"Prepare"), D("PersistView",1,""), D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",0,"PrepareOk"), D("PersistView",0,""), D("ReleaseReply",0,""),
 D("ClientOnReply",3,""),
 D("ReplicaOnMessage",2,"Prepare"), D("PersistView",2,""), D("ReleaseMessage",2,""),
 D("ReplicaOnMessage",0,"PrepareOk"), D("PersistView",0,""),
 D("ReplicaOnIdle",0,""), D("PersistView",0,""), D("ReleaseMessage",0,""), D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",1,"Commit"), D("PersistView",1,""),
 D("ReplicaOnMessage",2,"Commit"), D("PersistView",2,""),
 D("Crash",1,""), D("Recover",1,""), D("PersistView",1,""),
 D("ReleaseMessage",1,""), D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",0,"Recovery"), D("PersistView",0,""), D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",2,"Recovery"), D("PersistView",2,""), D("ReleaseMessage",2,""),
 D("ReplicaOnMessage",1,"RecoveryResponse"), D("PersistView",1,""),
 D("ReplicaOnMessage",1,"RecoveryResponse"), D("PersistView",1,""),
 D("ClientOnRequest",4,"Get"), D("ClientDrain",4,""),
 D("ReplicaOnMessage",0,"Request"), D("PersistView",0,""),
 D("ReleaseMessage",0,""), D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",1,"Prepare"), D("PersistView",1,""), D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",0,"PrepareOk"), D("PersistView",0,""), D("ReleaseReply",0,""),
 D("ClientOnReply",4,""),
 D("Pause",0,""),
 D("ReplicaOnIdle",1,""),
 D("PersistView",1,""),
 D("ReplicaOnIdle",1,""),
 D("PersistView",1,""),
 D("ReplicaOnIdle",1,""),
 D("PersistView",1,""),
 D("ReplicaOnIdle",1,""),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",2,"StartViewChange"),
 D("PersistView",2,""),
 D("ReleaseMessage",2,""),
 D("ReleaseMessage",2,""),
 D("ReleaseMessage",2,""),
 D("ReplicaOnMessage",1,"StartViewChange"),
 D("PersistView",1,""),
 D("ReplicaOnMessage",1,"DoViewChange"),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",2,"StartView"),
 D("PersistView",2,""),
 D("ReleaseMessage",2,""),
 D("ReplicaOnMessage",1,"PrepareOk"),
 D("PersistView",1,""),
 D("ReleaseReply",1,""),
 D("ClientOnReply",4,""),
 D("LoseMessage",0,"StartView"),
 D("Resume",0,""),
 D("ReplicaOnIdle",1,""),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",0,"Commit"),
 D("PersistView",0,""),
 D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",1,"GetState"),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",0,"NewState"),
 D("PersistView",0,""),
 D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",1,"PrepareOk"),
 D("PersistView",1,""),
 D("ReplicaOnMessage",2,"Prepare"),
 D("PersistView",2,""),
 D("ReplicaOnMessage",2,"Commit"),
 D("PersistView",2,""),
 D("ClientOnRequest",4,"Put"),
 D("ClientDrain",4,""),
 D("ReplicaOnMessage",1,"Request"),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReleaseMessage",1,""),
 D("LoseMessage",2,"Prepare"),
 D("ReplicaOnMessage",0,"Prepare"),
 D("PersistView",0,""),
 D("ReleaseMessage",0,""),
 D("ReplicaOnMessage",1,"PrepareOk"),
 D("PersistView",1,""),
 D("ReleaseReply",1,""),
 D("ClientOnReply",4,""),
 D("ReplicaOnIdle",1,""),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",2,"Commit"),
 D("PersistView",2,""),
 D("ReleaseMessage",2,""),
 D("ReplicaOnMessage",1,"GetState"),
 D("PersistView",1,""),
 D("ReleaseMessage",1,""),
 D("ReplicaOnMessage",2,"NewState"),
 D("PersistView",2,""),
 D("ReleaseMessage",2,""),
 D("ReplicaOnMessage",1,"PrepareOk"),
 D("PersistView",1,"")
>>
FInit ==
 /\ Init /\ l=1 /\ done=FALSE
 /\ records= <<[tag |-> "vsr", event |-> "Init", revision |-> "3ac0104a567092139534c9022205d02281a2da41",
      workload |-> "register-put-old-v1", replicas |-> <<0,1,2>>, clients |-> <<3,4>>,
      values |-> <<0,1,2>>, primaryTimeout |-> PrimaryTimeout, state |-> Snapshot]>>
Record(info,ap) == records'=Append(records,info @@ [tag |-> "vsr", state |-> Snapshot', applies |-> ap])
FStep ==
 /\ l<=Len(Script)
 /\ LET d == Script[l] t == d.target ev == d.event
    IN CASE ev="ClientOnRequest" ->
         LET x == [kind |-> d.kind, value |-> IF d.kind="Put" THEN 1 ELSE 0]
         IN ClientOnRequest(t,x) /\ Record([event |-> ev, client |-> t, input |-> x, request |-> clients[t].next],<<>>)
       [] ev="ClientDrain" -> ClientDrain(t) /\ Record([event |-> ev, client |-> t,
                                    message |-> ExportEnvelope(Head(clients[t].out))],<<>>)
       [] ev="ReplicaOnMessage" ->
         LET e == CHOOSE m \in DOMAIN network : m.dst=t /\ m.wire.kind=d.kind
         IN ReplicaOnMessage(t,e) /\ Record([event |-> ev, node |-> t,
                      message |-> ExportEnvelope(e), branch |-> MessageBranch(t,e)],ExpectedApplies(t))
       [] ev="ReplicaOnIdle" -> ReplicaOnIdle(t) /\ Record([event |-> ev, node |-> t,
                                                 branch |-> IdleBranch(t)],ExpectedApplies(t))
       [] ev="PersistView" -> PersistView(t) /\ Record([event |-> ev, node |-> t],<<>>)
       [] ev="ReleaseMessage" -> ReleaseMessage(t) /\ Record([event |-> ev, node |-> t,
                                  message |-> ExportEnvelope(Head(r[t].out))],<<>>)
       [] ev="ReleaseReply" -> ReleaseReply(t) /\ Record([event |-> ev, node |-> t,
                                  message |-> ExportEnvelope(Head(r[t].replies))],<<>>)
       [] ev="ClientOnReply" ->
          LET e == CHOOSE m \in DOMAIN replyChannel : m.dst=t
          IN ClientOnReply(t,e) /\ Record([event |-> ev, client |-> t,
                  message |-> ExportEnvelope(e), accepted |-> acceptedReplies'/=acceptedReplies],<<>>)
       [] ev="Pause" -> Pause(t) /\ Record([event |-> ev, node |-> t],<<>>)
       [] ev="Resume" -> Resume(t) /\ Record([event |-> ev, node |-> t],<<>>)
       [] ev="LoseMessage" ->
          LET e == CHOOSE m \in DOMAIN network : m.dst=t /\ m.wire.kind=d.kind
          IN LoseMessage(e) /\ Record([event |-> ev, message |-> ExportEnvelope(e)],<<>>)
       [] ev="Crash" -> Crash(t) /\ Record([event |-> ev, node |-> t],<<>>)
       [] ev="Recover" -> Recover(t) /\ Record([event |-> ev, node |-> t],<<>>)
 /\ l'=l+1 /\ UNCHANGED done
Finish == /\ l>Len(Script) /\ ~done /\ ndJsonSerialize("checks/trace-fixture.ndjson",records)
          /\ done'=TRUE /\ UNCHANGED <<vars,l,records>>
FSpec == FInit /\ [][FStep \/ Finish]_fv /\ WF_fv(FStep \/ Finish)
FixtureCompleted == <>done
=============================================================================
