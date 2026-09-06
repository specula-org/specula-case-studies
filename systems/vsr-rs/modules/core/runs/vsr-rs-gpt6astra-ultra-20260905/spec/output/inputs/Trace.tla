------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils

\* Category A: a single linear NDJSON history, including owner/transport steps.
\* A handler event contains its ordered apply calls; these are not interleavable.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
Tagged == SelectSeq(ndJsonDeserialize(JsonFile),LAMBDA e :
    "tag" \in DOMAIN e /\ e.tag="trace")
Meta == Head(Tagged)
TraceLog == Tail(Tagged)
TraceN == Len(Meta.replicas)
TraceClients == Elems(Meta.clients)
TraceValues == Elems(Meta.values)
TraceTimeout == Meta.primaryTimeout
VARIABLE l
traceVars == <<vars,l>>
logline == TraceLog[l]
IsEvent(name) == l<=Len(TraceLog) /\ logline.event=name
IsNodeEvent(name,i) == IsEvent(name) /\ logline.node=i

\* JSON encoding is unambiguous: optional entry is [] or [entry]; absent client
\* is the empty sequence. Every other normalized wire field is always present.
ExportWire(w) == [w EXCEPT !.entry=IF @=Nil THEN <<>> ELSE <<@>>,
                           !.client=IF @=Nil THEN <<>> ELSE <<@>>]
ExportEnvelope(e) == [e EXCEPT !.wire=ExportWire(@)]
ImportEnvelope(e) == [e EXCEPT !.wire.entry=IF @= <<>> THEN Nil ELSE Head(@),
    !.wire.client=IF e.wire.kind="Reply" THEN Head(@) ELSE Nil]
ExportSequence(s) == [k \in 1..Len(s) |-> ExportEnvelope(s[k])]
ExportBag(b) == {[message |-> ExportEnvelope(e), count |-> b[e]] : e \in DOMAIN b}

\* Source projection. All mutable fields in Replica (lib.rs:427-474) are checked,
\* apart from the S1-S2 ghost oracle fields, which remain independently computed.
ReplicaSnapshot(i) ==
 LET s == r[i]
 IN [id |-> i, status |-> s.status, view |-> s.view, lastNormal |-> s.lastNormal,
     commit |-> s.commit, log |-> s.log,
     acks |-> {[slot |-> k, replicas |-> s.acks[k]] : k \in DOMAIN s.acks},
     table |-> {[client |-> c, request |-> s.table[c].request,
                 hasReply |-> s.table[c].reply/=Nil,
                 reply |-> IF s.table[c].reply=Nil THEN 0 ELSE s.table[c].reply] : c \in DOMAIN s.table},
     heard |-> s.heard, waiting |-> s.waiting, attempts |-> s.attempts, stable |-> s.stable,
     svc |-> s.svc, dvcSent |-> s.dvcSent,
     dvc |-> {[replica |-> j, last |-> s.dvc[j].last,
                log |-> s.dvc[j].log, commit |-> s.dvc[j].commit] : j \in DOMAIN s.dvc},
     catching |-> s.catching, nonce |-> s.nonce,
     responses |-> {[replica |-> j, view |-> s.responses[j].view,
                      hasState |-> s.responses[j].hasState,
                      log |-> s.responses[j].log, commit |-> s.responses[j].commit] : j \in DOMAIN s.responses},
     out |-> ExportSequence(s.out), replies |-> ExportSequence(s.replies),
     app |-> s.app, applied |-> s.applied, results |-> s.results]
ClientSnapshot(c) == [view |-> clients[c].view, next |-> clients[c].next,
   pending |-> IF clients[c].pending=Nil THEN <<>> ELSE <<clients[c].pending>>,
   out |-> ExportSequence(clients[c].out)]
Snapshot ==
 [replicas |-> [j \in 1..N |-> ReplicaSnapshot(j-1)],
  durableViews |-> [j \in 1..N |-> durableView[j-1]],
  lives |-> [j \in 1..N |-> life[j-1]], phases |-> [j \in 1..N |-> phase[j-1]],
  incarnations |-> [j \in 1..N |-> incarnation[j-1]],
  clients |-> {[id |-> c, state |-> ClientSnapshot(c)] : c \in Clients}, retiredClients |-> retiredClients,
  invocations |-> {Entry(k[1],k[2],requestInput[k]) : k \in DOMAIN requestInput},
  acceptedReplies |-> {ExportEnvelope(e) : e \in acceptedReplies},
  network |-> ExportBag(network), replyChannel |-> ExportBag(replyChannel),
  released |-> {ExportEnvelope(e) : e \in released},
  applications |-> {[replica |-> k[1], incarnation |-> k[2], entries |-> appliedByIncarnation[k]] :
                     k \in DOMAIN appliedByIncarnation}]
\* JSON arrays representing sets are normalized explicitly. Sequence order is
\* preserved for logs, both outboxes, results and per-incarnation apply histories.
NormalizeReplica(s) == [s EXCEPT
  !.acks={[slot |-> a.slot, replicas |-> Elems(a.replicas)] : a \in Elems(@)},
  !.table=Elems(@), !.svc=Elems(@), !.dvc=Elems(@), !.responses=Elems(@),
  !.attempts=Min(@,10), !.stable=Min(@,PrimaryTimeout)]
NormalizeSnapshot(s) == [s EXCEPT
  !.replicas=[j \in 1..Len(@) |-> NormalizeReplica(@[j])],
  !.clients=Elems(@), !.retiredClients=Elems(@), !.invocations=Elems(@), !.acceptedReplies=Elems(@),
  !.network=Elems(@), !.replyChannel=Elems(@), !.released=Elems(@), !.applications=Elems(@)]

\* No optional-field fallback: a missing/mismatching captured field REJECTS the event.
ValidatePostState == NormalizeSnapshot(logline.state)=Snapshot'
ValidateNoApply == logline.applies= <<>>
ExpectedApplies(i) ==
 [j \in 1..(Len(r'[i].applied)-Len(r[i].applied)) |->
   LET k == Len(r[i].applied)+j
       e == r'[i].applied[k]
       before == r'[i].results[k]
   IN [slot |-> k, entry |-> e, stateBefore |-> before,
       result |-> before, stateAfter |-> ApplyValue(before,e.input)]]
ValidateApplies(i) == logline.applies=ExpectedApplies(i)
Advance == l'=l+1

\* Branch is derived from PRE-state, never chosen to make a trace fit.
MessageBranch(i,e) ==
 LET s == r[i] m == e.wire
 IN IF s.status="Recovering" /\ m.kind/="RecoveryResponse" THEN "ignore-recovering"
    ELSE CASE m.kind="Request" ->
           IF ~IsPrimary(i,s) \/ s.status/="Normal" THEN "ignore-role-status"
           ELSE IF m.entry.client \in DOMAIN s.table
                THEN IF m.entry.request<s.table[m.entry.client].request THEN "old-request"
                     ELSE IF m.entry.request=s.table[m.entry.client].request THEN "duplicate-request"
                     ELSE "append-request"
                ELSE "append-request"
      [] m.kind \in {"Prepare","Commit"} ->
           IF m.view<s.view THEN "old-view"
           ELSE IF m.view>s.view THEN "catch-up-new-view"
           ELSE IF s.status="ViewChange" THEN "catch-up-same-view"
           ELSE IF s.status/="Normal" \/ IsPrimary(i,s) THEN "ignore-role-status"
           ELSE IF (IF m.kind="Prepare" THEN m.opn>Len(s.log)+1 ELSE m.commit>Len(s.log))
                THEN "state-transfer"
           ELSE IF m.kind="Prepare" /\ m.opn=Len(s.log)+1 THEN "append-prepare"
           ELSE "normal"
      [] m.kind="NewState" ->
           IF m.view/=s.view THEN "different-view"
           ELSE IF s.status="StateTransfer" THEN "same-view-transfer"
           ELSE IF s.status="ViewChange" /\ s.catching THEN "view-catch-up"
           ELSE "ignore-status"
      [] OTHER -> m.kind
IdleBranch(i) == CASE r[i].status="Normal" /\ IsPrimary(i,r[i]) -> "primary"
                     [] r[i].status="Recovering" -> "recovering"
                     [] r[i].status="ViewChange" -> "view-change"
                     [] OTHER -> "backup-or-transfer"

\* lib.rs:528-641. Full dispatch and every source branch execute in the base.
TraceReplicaOnMessage ==
  /\ IsEvent("ReplicaOnMessage")
  /\ LET i == logline.node e == ImportEnvelope(logline.message)
     IN /\ logline.branch=MessageBranch(i,e)
        /\ ReplicaOnMessage(i,e) /\ ValidateApplies(i)
  /\ ValidatePostState /\ Advance
\* lib.rs:1233-1285, all idle branches, including timeout and retransmission effects.
TraceReplicaOnIdle ==
  /\ IsEvent("ReplicaOnIdle")
  /\ LET i == logline.node
     IN /\ logline.branch=IdleBranch(i) /\ ReplicaOnIdle(i) /\ ValidateApplies(i)
  /\ ValidatePostState /\ Advance
\* lib.rs:14-18 / example:749; post-state includes durable view and publication phase.
TracePersistView ==
  /\ IsEvent("PersistView") /\ PersistView(logline.node)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
\* lib.rs:1468-1474. Event packet must be exactly the PRE-state head being drained.
TraceReleaseMessage ==
  /\ IsEvent("ReleaseMessage")
  /\ ImportEnvelope(logline.message)=Head(r[logline.node].out)
  /\ ReleaseMessage(logline.node) /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceReleaseReply ==
  /\ IsEvent("ReleaseReply")
  /\ ImportEnvelope(logline.message)=Head(r[logline.node].replies)
  /\ ReleaseReply(logline.node) /\ ValidatePostState /\ ValidateNoApply /\ Advance
\* S1 owner faults, lib.rs:14-18,505-524. Every boundary has an explicit event.
TracePause == /\ IsEvent("Pause") /\ Pause(logline.node)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceResume == /\ IsEvent("Resume") /\ Resume(logline.node)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceCrash == /\ IsEvent("Crash") /\ Crash(logline.node)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceRecover == /\ IsEvent("Recover") /\ Recover(logline.node)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
\* lib.rs:312-326,353-375,334-347 and client-lifetime owner obligation 29-31.
TraceClientOnRequest ==
  /\ IsEvent("ClientOnRequest") /\ ClientOnRequest(logline.client,logline.input)
  /\ logline.request=clients[logline.client].next
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceClientOnIdle == /\ IsEvent("ClientOnIdle") /\ ClientOnIdle(logline.client)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceClientDrain ==
  /\ IsEvent("ClientDrain")
  /\ ImportEnvelope(logline.message)=Head(clients[logline.client].out)
  /\ ClientDrain(logline.client) /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceClientOnReply ==
  /\ IsEvent("ClientOnReply")
  /\ ClientOnReply(logline.client,ImportEnvelope(logline.message))
  /\ logline.accepted=(acceptedReplies'/=acceptedReplies)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceClientRetire == /\ IsEvent("ClientRetire") /\ ClientRetire(logline.client)
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
\* S1-S3 scheduler hooks: lose/replay the actual immutable released packet.
TraceLoseMessage == /\ IsEvent("LoseMessage") /\ LoseMessage(ImportEnvelope(logline.message))
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceLoseReply == /\ IsEvent("LoseReply") /\ LoseReply(ImportEnvelope(logline.message))
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceReplayMessage == /\ IsEvent("ReplayMessage") /\ ReplayMessage(ImportEnvelope(logline.message))
  /\ ValidatePostState /\ ValidateNoApply /\ Advance
TraceReplayReply == /\ IsEvent("ReplayReply") /\ ReplayReply(ImportEnvelope(logline.message))
  /\ ValidatePostState /\ ValidateNoApply /\ Advance

TraceInit ==
  /\ Assert(Len(Tagged)>1,"trace must contain Init and at least one transition")
  /\ Assert(Meta.event="Init" /\ Meta.revision="3ac0104a567092139534c9022205d02281a2da41",
            "wrong trace bootstrap or revision")
  /\ Assert(Meta.workload="register-put-old-v1","incompatible application workload")
  /\ Assert(Meta.replicas=[j \in 1..N |-> j-1],"replica IDs must match Config::add_replica")
  /\ Assert(Cardinality(Clients)=Len(Meta.clients),"duplicate client lifetime identity")
  /\ Assert(Clients \subseteq Nat /\ Clients \cap Server={},"use disjoint numeric endpoint IDs")
  /\ Init /\ l=1 /\ NormalizeSnapshot(Meta.state)=Snapshot
Consume ==
  /\ l<=Len(TraceLog)
  /\ \/ TraceReplicaOnMessage \/ TraceReplicaOnIdle
     \/ TracePersistView \/ TraceReleaseMessage \/ TraceReleaseReply
     \/ TracePause \/ TraceResume \/ TraceCrash \/ TraceRecover
     \/ TraceClientOnRequest \/ TraceClientOnIdle \/ TraceClientDrain
     \/ TraceClientOnReply \/ TraceClientRetire
     \/ TraceLoseMessage \/ TraceLoseReply \/ TraceReplayMessage \/ TraceReplayReply
\* No silent actions: persistence, draining, network faults and ticks are captured.
TraceNext == Consume \/ (l>Len(TraceLog) /\ UNCHANGED traceVars)
\* Fairness excludes gratuitous stuttering when the next event matches. If it
\* cannot match, Consume is disabled, and TraceMatched fails (including at line 1).
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(Consume)
TraceMatched == <>(l>Len(TraceLog))
=============================================================================
