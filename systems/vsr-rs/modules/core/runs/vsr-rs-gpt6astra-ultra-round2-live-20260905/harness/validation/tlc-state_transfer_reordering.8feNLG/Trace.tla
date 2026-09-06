------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
\* Category A: one globally ordered event for each atomic owner/library call.
\* Full fresh bootstrap required; no arbitrary state seeding from observations.
JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
            ELSE "../traces/trace.ndjson"
RawTrace == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTrace,LAMBDA e :
    IF "tag" \in DOMAIN e THEN e.tag="trace" ELSE FALSE)
Header == TraceLog[1]
TraceN == Len(Header.servers)
TraceClients == Elements(Header.clientIds)
TraceOperations == Elements(Header.operations)
TraceTimeout == Header.primaryTimeout

VARIABLE l
tracevars == <<vars,l>>
logline == TraceLog[l]
IsEvent(name) == l<=Len(TraceLog) /\ logline.event=name
IsNodeEvent(name,i) == IsEvent(name) /\ logline.node=i
IsClientEvent(name,c) == IsEvent(name) /\ logline.client=c

\* JSON encodes finite maps as [{key,value},...], preserving numeric keys.
\* Arrays become sequences; sender/ack/nonces sets are explicitly normalized.
Keys(es) == {e.key : e \in Elements(es)}
UniqueKeys(es) == Cardinality(Keys(es))=Len(es)
Assoc(es) == [k \in Keys(es) |-> (CHOOSE e \in Elements(es) : e.key=k).value]
AckMap(es) == [k \in Keys(es) |-> Elements(Assoc(es)[k])]
DecodeReplica(s) ==
    [s EXCEPT !.acks=AckMap(s.acks), !.table=Assoc(s.table),
              !.svc=Elements(s.svc), !.dvc=Assoc(s.dvc),
              !.responses=Assoc(s.responses)]
ReplicaIDs(e) == {r.id : r \in Elements(e.replicas)}
ClientIDs(e) == {c.id : c \in Elements(e.clients)}
ReplicaRows(e) == [i \in ReplicaIDs(e) |->
                         CHOOSE r \in Elements(e.replicas) : r.id=i]
ClientRows(e) == [c \in ClientIDs(e) |->
                         CHOOSE r \in Elements(e.clients) : r.id=c]
CapturedReplicas(e) == [i \in Servers |-> DecodeReplica(ReplicaRows(e)[i].state)]
CapturedClients(e) == [c \in Clients |-> ClientRows(e)[c].state]
CapturedDurable(e) == [i \in Servers |-> ReplicaRows(e)[i].durableView]
CapturedLive(e) == {i \in Servers : ReplicaRows(e)[i].live}
CapturedIncarnations(e) == [i \in Servers |-> ReplicaRows(e)[i].incarnation]
CapturedNonces(e) == [i \in Servers |-> Elements(ReplicaRows(e)[i].usedNonces)]

SnapshotShape(e) ==
    /\ ReplicaIDs(e)=Servers /\ Len(e.replicas)=N
    /\ ClientIDs(e)=Clients /\ Len(e.clients)=Cardinality(Clients)
    /\ \A i \in Servers :
        LET s == ReplicaRows(e)[i].state IN
        /\ DOMAIN s=DOMAIN NewReplica
        /\ UniqueKeys(s.acks) /\ UniqueKeys(s.table)
        /\ UniqueKeys(s.dvc) /\ UniqueKeys(s.responses)
        /\ Cardinality(Elements(s.svc))=Len(s.svc)
        /\ \A a \in Elements(s.acks) : Cardinality(Elements(a.value))=Len(a.value)
        /\ Cardinality(Elements(ReplicaRows(e)[i].usedNonces))=Len(ReplicaRows(e)[i].usedNonces)
    /\ \A c \in Clients : DOMAIN ClientRows(e)[c].state=DOMAIN NewClient

\* All captured protocol, application, client, durability and environment fields
\* are REQUIRED and compared; there are no conditional 'field present' checks.
\* Ghost committed/reply histories are rebuilt by base actions, never imported.
ValidatePostState(e) ==
    /\ SnapshotShape(e)
    /\ replicas'=CapturedReplicas(e) /\ clients'=CapturedClients(e)
    /\ durableView'=CapturedDurable(e) /\ live'=CapturedLive(e)
    /\ incarnations'=CapturedIncarnations(e) /\ usedNonces'=CapturedNonces(e)
    /\ network'=BagAdd(EmptyMap,e.network)
    /\ lastOutput'=e.outputs
ValidateInitialState(e) ==
    /\ SnapshotShape(e)
    /\ replicas=CapturedReplicas(e) /\ clients=CapturedClients(e)
    /\ durableView=CapturedDurable(e) /\ live=CapturedLive(e)
    /\ incarnations=CapturedIncarnations(e) /\ usedNonces=CapturedNonces(e)
    /\ network=BagAdd(EmptyMap,e.network) /\ lastOutput=e.outputs

TraceInit ==
    /\ Len(TraceLog)>=1
    /\ Header.event="Init" /\ Header.schema=1 /\ Header.system="vsr-rs"
    /\ Header.revision="3ac0104a567092139534c9022205d02281a2da41"
    /\ Header.category="A" /\ Header.application="integer-sum"
    /\ Header.servers=[k \in 1..N |-> k-1]
    /\ Len(Header.clientIds)=Cardinality(Clients)
    /\ Len(Header.operations)=Cardinality(Operations)
    /\ Init /\ ValidateInitialState(Header) /\ l=2

\* Every wrapper invokes the FULL corresponding base action, consumes one
\* event, and validates the full post-state. No silent protocol steps exist.
TraceOnRequest(i) ==
    /\ IsNodeEvent("OnRequest",i) /\ OnRequest(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnPrepare(i) ==
    /\ IsNodeEvent("OnPrepare",i) /\ OnPrepare(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnPrepareOk(i) ==
    /\ IsNodeEvent("OnPrepareOk",i) /\ OnPrepareOk(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnCommit(i) ==
    /\ IsNodeEvent("OnCommit",i) /\ OnCommit(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnGetState(i) ==
    /\ IsNodeEvent("OnGetState",i) /\ OnGetState(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnNewState(i) ==
    /\ IsNodeEvent("OnNewState",i) /\ OnNewState(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnStartViewChange(i) ==
    /\ IsNodeEvent("OnStartViewChange",i) /\ OnStartViewChange(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnDoViewChange(i) ==
    /\ IsNodeEvent("OnDoViewChange",i) /\ OnDoViewChange(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnStartView(i) ==
    /\ IsNodeEvent("OnStartView",i) /\ OnStartView(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnRecovery(i) ==
    /\ IsNodeEvent("OnRecovery",i) /\ OnRecovery(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnRecoveryResponse(i) ==
    /\ IsNodeEvent("OnRecoveryResponse",i) /\ OnRecoveryResponse(i,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceOnIdle(i) ==
    /\ IsNodeEvent("OnIdle",i) /\ OnIdle(i)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceCrash(i) ==
    /\ IsNodeEvent("Crash",i) /\ Crash(i)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceRecover(i) ==
    /\ IsNodeEvent("Recover",i) /\ Recover(i,logline.nonce)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceClientOnRequest(c) ==
    /\ IsClientEvent("ClientOnRequest",c) /\ logline.op \in Operations
    /\ ClientOnRequest(c,logline.op)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceClientOnIdle(c) ==
    /\ IsClientEvent("ClientOnIdle",c) /\ ClientOnIdle(c)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceClientOnReply(c) ==
    /\ IsClientEvent("ClientOnReply",c) /\ ClientOnReply(c,logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceLose ==
    /\ IsEvent("Lose") /\ Lose(logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1
TraceDuplicate ==
    /\ IsEvent("Duplicate") /\ Duplicate(logline.message)
    /\ ValidatePostState(logline) /\ l'=l+1

TraceStep ==
    /\ l<=Len(TraceLog)
    /\ \/ \E i \in Servers :
              \/ TraceOnRequest(i) \/ TraceOnPrepare(i) \/ TraceOnPrepareOk(i)
              \/ TraceOnCommit(i) \/ TraceOnGetState(i) \/ TraceOnNewState(i)
              \/ TraceOnStartViewChange(i) \/ TraceOnDoViewChange(i)
              \/ TraceOnStartView(i) \/ TraceOnRecovery(i) \/ TraceOnRecoveryResponse(i)
              \/ TraceOnIdle(i) \/ TraceCrash(i) \/ TraceRecover(i)
       \/ \E c \in Clients : TraceClientOnRequest(c) \/ TraceClientOnIdle(c) \/ TraceClientOnReply(c)
       \/ TraceLose \/ TraceDuplicate
TraceNext == TraceStep \/ (l>Len(TraceLog) /\ UNCHANGED tracevars)
\* Replay fairness only forces an enabled next event to be consumed. It says
\* nothing about protocol liveness. A mismatched event is disabled and fails
\* TraceMatched; no trace-skipping action can rescue it.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceStep)
TraceMatched == <>(l>Len(TraceLog))
=============================================================================
