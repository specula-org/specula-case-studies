------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
VARIABLE l
tracevars == <<vars,l>>
JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON ELSE "../traces/trace.ndjson"
RawTrace == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTrace,LAMBDA e:IF "tag" \in DOMAIN e THEN e.tag="trace" ELSE FALSE)
Metadata == TraceLog[1].config
TraceServers == SeqSet(Metadata.servers)
TraceClients == SeqSet(Metadata.clients)
TraceValues == SeqSet(Metadata.values)
TraceTimeout == Metadata.primary_timeout
TraceFailureBudget == Metadata.failure_budget
TraceIntegration == Metadata.integration_mode
TraceFullValue == Metadata.full_value
TracePrefixValue == Metadata.prefix_value

\* NDJSON maps use arrays of keyed rows, never JSON's stringified numeric keys.
\* Missing fields are errors; there are no optional/vacuously true state checks.
RowsById(xs) == [i \in {x.id:x \in SeqSet(xs)} |-> CHOOSE x \in SeqSet(xs):x.id=i]
RowsBySrc(xs) == [i \in {x.src:x \in SeqSet(xs)} |-> CHOOSE x \in SeqSet(xs):x.src=i]
AckMap(xs) == [k \in {x.opnum:x \in SeqSet(xs)} |->
                        SeqSet((CHOOSE x \in SeqSet(xs):x.opnum=k).from)]
TableMap(xs) == [c \in {x.client:x \in SeqSet(xs)} |->
 LET e == CHOOSE x \in SeqSet(xs):x.client=c
 IN [request |-> e.request,hasReply |-> e.hasReply,result |-> e.result]]
NormReplica(p) == [status |-> p.status,view |-> p.view,lastNormal |-> p.lastNormal,
 log |-> p.log,commit |-> p.commit,acks |-> AckMap(p.acks),table |-> TableMap(p.table),
 heard |-> p.heard,waiting |-> p.waiting,attempts |-> Min(p.attempts,10),
 stable |-> Min(p.stable,PrimaryTimeout),svc |-> SeqSet(p.svc),dvcSent |-> p.dvcSent,
 dvc |-> RowsBySrc(p.dvc),catching |-> p.catching,nonce |-> p.nonce,
 responses |-> RowsBySrc(p.responses),messages |-> p.messages,replies |-> p.replies,
 app |-> p.app,executed |-> p.executed]
ObservedReplica(s) == [status |-> s.status,view |-> s.view,lastNormal |-> s.lastNormal,
 log |-> s.log,commit |-> s.commit,acks |-> s.acks,table |-> s.table,
 heard |-> s.heard,waiting |-> s.waiting,attempts |-> s.attempts,stable |-> s.stable,
 svc |-> s.svc,dvcSent |-> s.dvcSent,dvc |-> s.dvc,catching |-> s.catching,
 nonce |-> s.nonce,responses |-> s.responses,messages |-> s.messages,
 replies |-> s.replies,app |-> s.app,executed |-> s.executed]
NormClient(p) == [view |-> p.view,next |-> p.next,pending |-> p.pending,entry |-> p.entry]
EntryMap(xs) == [id \in {RequestId(e):e \in SeqSet(xs)} |->
                       CHOOSE e \in SeqSet(xs):RequestId(e)=id]
ResultMap(xs) == [id \in {<<e.client,e.request>>:e \in SeqSet(xs)} |->
                       (CHOOSE e \in SeqSet(xs):<<e.client,e.request>>=id).result]
NormSnapshot(p) ==
 LET rs == RowsById(p.replicas)
     cs == RowsById(p.clients)
     fs == RowsById(p.frames)
 IN [replicas |-> [i \in DOMAIN rs |-> NormReplica(rs[i].state)],
     durable |-> [i \in DOMAIN rs |-> rs[i].durable],
     owners |-> [i \in DOMAIN rs |-> rs[i].owner],
     incarnations |-> [i \in DOMAIN rs |-> rs[i].incarnation],
     clients |-> [c \in DOMAIN cs |-> NormClient(cs[c])],
     network |-> SeqSet(p.network),
     frames |-> [f \in DOMAIN fs |->
                   [sent |-> fs[f].sent,stage |-> fs[f].stage,admitted |-> fs[f].admitted]],
     nextFrame |-> p.nextFrame,phase |-> p.phase,healthySet |-> SeqSet(p.healthySet),
     invocations |-> EntryMap(p.invocations),responses |-> ResultMap(p.responses),
     happensBefore |-> SeqSet(p.happensBefore),committedHistory |-> SeqSet(p.committedHistory)]
ModelSnapshot ==
 [replicas |-> [i \in Server |-> ObservedReplica(replica[i])],
  durable |-> durableView,owners |-> owner,incarnations |-> incarnation,
  clients |-> client,network |-> network,frames |-> tx,nextFrame |-> nextFrame,
  phase |-> phase,healthySet |-> healthySet,invocations |-> invocations,
  responses |-> responses,happensBefore |-> happensBefore,committedHistory |-> committedHistory]
ValidatePostState(p) == ModelSnapshot'=NormSnapshot(p)
IsEvent(e,name) == e.event=name
Advance(e) == /\ ValidatePostState(e.post) /\ l'=l+1

\* Generated wrappers below each call the COMPLETE base action. Their shared
\* validator compares every captured local/global state field, including full
\* messages, log contents, cached replies, response maps and durable/output state.
TraceRecoveringDrop(e) ==
 /\ IsEvent(e,"RecoveringDrop") /\ RecoveringDrop(e.node,e.message,e.keep) /\ Advance(e)
TraceOnRequest(e) ==
 /\ IsEvent(e,"OnRequest") /\ OnRequest(e.node,e.message,e.keep) /\ Advance(e)
TraceOnPrepareRejected(e) ==
 /\ IsEvent(e,"OnPrepareRejected") /\ OnPrepareRejected(e.node,e.message,e.keep) /\ Advance(e)
TraceOnPrepareGap(e) ==
 /\ IsEvent(e,"OnPrepareGap") /\ OnPrepareGap(e.node,e.message,e.keep) /\ Advance(e)
TraceOnPrepareAppend(e) ==
 /\ IsEvent(e,"OnPrepareAppend") /\ OnPrepareAppend(e.node,e.message,e.keep) /\ Advance(e)
TraceOnPrepareDuplicate(e) ==
 /\ IsEvent(e,"OnPrepareDuplicate") /\ OnPrepareDuplicate(e.node,e.message,e.keep) /\ Advance(e)
TraceOnPrepareOk(e) ==
 /\ IsEvent(e,"OnPrepareOk") /\ OnPrepareOk(e.node,e.message,e.keep) /\ Advance(e)
TraceOnCommit(e) ==
 /\ IsEvent(e,"OnCommit") /\ OnCommit(e.node,e.message,e.keep) /\ Advance(e)
TraceOnGetState(e) ==
 /\ IsEvent(e,"OnGetState") /\ OnGetState(e.node,e.message,e.keep) /\ Advance(e)
TraceOnNewStateTransfer(e) ==
 /\ IsEvent(e,"OnNewStateTransfer") /\ OnNewStateTransfer(e.node,e.message,e.keep) /\ Advance(e)
TraceOnNewStateCatchUp(e) ==
 /\ IsEvent(e,"OnNewStateCatchUp") /\ OnNewStateCatchUp(e.node,e.message,e.keep) /\ Advance(e)
TraceOnNewStateIgnored(e) ==
 /\ IsEvent(e,"OnNewStateIgnored") /\ OnNewStateIgnored(e.node,e.message,e.keep) /\ Advance(e)
TraceOnStartViewChange(e) ==
 /\ IsEvent(e,"OnStartViewChange") /\ OnStartViewChange(e.node,e.message,e.keep) /\ Advance(e)
TraceOnDoViewChange(e) ==
 /\ IsEvent(e,"OnDoViewChange") /\ OnDoViewChange(e.node,e.message,e.keep) /\ Advance(e)
TraceOnStartView(e) ==
 /\ IsEvent(e,"OnStartView") /\ OnStartView(e.node,e.message,e.keep) /\ Advance(e)
TraceOnRecovery(e) ==
 /\ IsEvent(e,"OnRecovery") /\ OnRecovery(e.node,e.message,e.keep) /\ Advance(e)
TraceOnRecoveryResponse(e) ==
 /\ IsEvent(e,"OnRecoveryResponse") /\ OnRecoveryResponse(e.node,e.message,e.keep) /\ Advance(e)
TraceOnIdle(e) ==
 /\ IsEvent(e,"OnIdle") /\ OnIdle(e.node) /\ Advance(e)
TracePersistView(e) ==
 /\ IsEvent(e,"PersistView") /\ PersistView(e.node) /\ Advance(e)
TracePublishOutput(e) ==
 /\ IsEvent(e,"PublishOutput") /\ PublishOutput(e.node) /\ Advance(e)
TraceCrash(e) ==
 /\ IsEvent(e,"Crash") /\ Crash(e.node) /\ Advance(e)
TraceRecover(e) ==
 /\ IsEvent(e,"Recover") /\ Recover(e.node) /\ Advance(e)
TraceRunSenderBeginPartial(e) ==
 /\ IsEvent(e,"RunSenderBeginPartial") /\ RunSenderBeginPartial(e.frame) /\ Advance(e)
TraceRunSenderComplete(e) ==
 /\ IsEvent(e,"RunSenderComplete") /\ RunSenderComplete(e.frame) /\ Advance(e)
TraceRunPeerAcceptorEOF(e) ==
 /\ IsEvent(e,"RunPeerAcceptorEOF") /\ RunPeerAcceptorEOF(e.frame) /\ Advance(e)
TraceRunPeerAcceptorReadError(e) ==
 /\ IsEvent(e,"RunPeerAcceptorReadError") /\ RunPeerAcceptorReadError(e.frame) /\ Advance(e)
TraceLoseMessage(e) ==
 /\ IsEvent(e,"LoseMessage") /\ LoseMessage(e.message) /\ Advance(e)
TraceDiscardUnavailable(e) ==
 /\ IsEvent(e,"DiscardUnavailable") /\ DiscardUnavailable(e.message) /\ Advance(e)
TraceClientOnRequest(e) ==
 /\ IsEvent(e,"ClientOnRequest") /\ ClientOnRequest(e.client,e.op) /\ Advance(e)
TraceClientOnIdle(e) ==
 /\ IsEvent(e,"ClientOnIdle") /\ ClientOnIdle(e.client) /\ Advance(e)
TraceClientOnReply(e) ==
 /\ IsEvent(e,"ClientOnReply") /\ ClientOnReply(e.message,e.keep) /\ Advance(e)
TraceStabilize(e) ==
 /\ IsEvent(e,"Stabilize") /\ Stabilize(SeqSet(e.healthy)) /\ Advance(e)

TraceInit ==
 /\ Len(TraceLog)>=1 /\ TraceLog[1].event="Init"
 /\ Metadata.revision="3ac0104a567092139534c9022205d02281a2da41"
 /\ Init /\ ModelSnapshot=NormSnapshot(TraceLog[1].post) /\ l=2
TraceNext ==
 \/ /\ l<=Len(TraceLog)
    /\ LET e == TraceLog[l] IN
        \/ TraceRecoveringDrop(e)
        \/ TraceOnRequest(e)
        \/ TraceOnPrepareRejected(e)
        \/ TraceOnPrepareGap(e)
        \/ TraceOnPrepareAppend(e)
        \/ TraceOnPrepareDuplicate(e)
        \/ TraceOnPrepareOk(e)
        \/ TraceOnCommit(e)
        \/ TraceOnGetState(e)
        \/ TraceOnNewStateTransfer(e)
        \/ TraceOnNewStateCatchUp(e)
        \/ TraceOnNewStateIgnored(e)
        \/ TraceOnStartViewChange(e)
        \/ TraceOnDoViewChange(e)
        \/ TraceOnStartView(e)
        \/ TraceOnRecovery(e)
        \/ TraceOnRecoveryResponse(e)
        \/ TraceOnIdle(e)
        \/ TracePersistView(e)
        \/ TracePublishOutput(e)
        \/ TraceCrash(e)
        \/ TraceRecover(e)
        \/ TraceRunSenderBeginPartial(e)
        \/ TraceRunSenderComplete(e)
        \/ TraceRunPeerAcceptorEOF(e)
        \/ TraceRunPeerAcceptorReadError(e)
        \/ TraceLoseMessage(e)
        \/ TraceDiscardUnavailable(e)
        \/ TraceClientOnRequest(e)
        \/ TraceClientOnIdle(e)
        \/ TraceClientOnReply(e)
        \/ TraceStabilize(e)
 \/ /\ l>Len(TraceLog) /\ UNCHANGED tracevars
\* No silent actions: every owner, transport, timer and crash boundary can
\* be instrumented. Missing events must fail instead of being invented.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <> (l>Len(TraceLog))
=============================================================================
