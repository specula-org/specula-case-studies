------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, Bags, TLC

(***************************************************************************
 Category A; source revision 3ac0104a567092139534c9022205d02281a2da41.
 Scope: modeling-brief S1-S3. S4 caller obligations are assumed, not removed.
 Each synchronous Rust handler and its helper calls form ONE transition.
 Functional helpers below preserve statement order; they are not extra steps.
 PersistView and individual drain/publication steps are separate crash windows.
 Incarnations and acknowledgement prefixes are observer metadata, NEVER guards
 on a received wire message. No integer/nonce/view/client identity wraps.
***************************************************************************)
CONSTANTS Nil, N, Clients, Values, PrimaryTimeout
Server == 0..(N-1)
Quorum == (N \div 2) + 1
FailureBudget == (N-1) \div 2
ASSUME /\ N \in Nat \ {0} /\ PrimaryTimeout \in Nat \ {0}
       /\ IsFiniteSet(Clients) /\ Clients/={} /\ IsFiniteSet(Values)
       /\ Values \subseteq Nat /\ 0 \in Values
       /\ Nil \notin Clients \cup Values \cup Server
Primary(v) == v % N                       \* lib.rs:86-98
Min(a,b) == IF a < b THEN a ELSE b
Max(a,b) == IF a > b THEN a ELSE b
MaxSet(s) == CHOOSE x \in s : \A y \in s : x >= y
EmptyMap == [x \in {} |-> x]
PutMap(f,k,v) == [x \in DOMAIN f \cup {k} |-> IF x=k THEN v ELSE f[x]]
Restrict(f,d) == [x \in d |-> f[x]]
Prefix(s,n) == SubSeq(s,1,n)
Compatible(a,b) == Prefix(a,Min(Len(a),Len(b))) = Prefix(b,Min(Len(a),Len(b)))
IsPrefix(a,b) == Len(a)<=Len(b) /\ a=Prefix(b,Len(a))
Elems(s) == {s[k] : k \in 1..Len(s)}
RECURSIVE ToBag(_)
ToBag(s) == IF s = <<>> THEN EmptyBag ELSE (SetToBag({Head(s)}) \oplus ToBag(Tail(s)))
AddBag(b,s) == (b \oplus ToBag(s))
RemoveOne(b,m) == (b \ominus SetToBag({m}))

\* S2 independent deterministic register workload (StateMachine, lib.rs:53-60).
\* Put returns the old value; Get returns the current value; initial value 0.
Inputs == {[kind |-> "Put", value |-> v] : v \in Values} \cup
          {[kind |-> "Get", value |-> 0]}
Entry(c,q,x) == [client |-> c, request |-> q, input |-> x]
Key(e) == <<e.client,e.request>>
ApplyValue(a,x) == IF x.kind="Put" THEN x.value ELSE a
ApplyResult(a,x) == a
RECURSIVE ReplayState(_), ReplayResults(_)
ReplayState(h) == IF h = <<>> THEN 0 ELSE
    IF h[Len(h)].input.kind="Put" THEN h[Len(h)].input.value
    ELSE ReplayState(Prefix(h,Len(h)-1))
ReplayResults(h) == IF h = <<>> THEN <<>> ELSE
    Append(ReplayResults(Prefix(h,Len(h)-1)),ReplayState(Prefix(h,Len(h)-1)))

\* Normalized union of wire variants, lib.rs:142-262; unused fields are defaults.
Wire(t,v) == [kind |-> t, view |-> v, opn |-> 0, commit |-> 0,
  entry |-> Nil, log |-> <<>>, start |-> 0, last |-> 0,
  nonce |-> 0, hasState |-> FALSE, client |-> Nil, request |-> 0,
  result |-> 0]
Envelope(src,dst,w,inc,p) == [src |-> src, dst |-> dst, wire |-> w,
                              incarnation |-> inc, proof |-> p]
Ack(i,s,k) == [node |-> i, incarnation |-> s.incarnation,
               view |-> s.view, slot |-> k, prefix |-> Prefix(s.log,k)]

VARIABLES r, durableView, life, phase, incarnation,
          clients, retiredClients, requestInput, acceptedReplies,
          network, replyChannel, released,
          ackHistory, quorumHistory, installedViewHistory,
          appliedByIncarnation, historicalPrefixes, logicalHistory,
          primaryHistory, acceptanceHistory
replicaVars == <<r,durableView,life,phase,incarnation>>
clientVars == <<clients,retiredClients,requestInput,acceptedReplies>>
channelVars == <<network,replyChannel,released>>
historyVars == <<ackHistory,quorumHistory,installedViewHistory,
                 appliedByIncarnation,historicalPrefixes,logicalHistory,primaryHistory,acceptanceHistory>>
vars == <<replicaVars,clientVars,channelVars,historyVars>>

\* lib.rs:478-502. app/applied/results/assertionFailed and *Marks are S1-S2 observers.
NewReplica(inc) == [status |-> "Normal", view |-> 0, lastNormal |-> 0,
  commit |-> 0, log |-> <<>>, acks |-> EmptyMap, table |-> EmptyMap,
  heard |-> TRUE, waiting |-> 0, attempts |-> 0, stable |-> 0,
  svc |-> {}, dvcSent |-> FALSE, dvc |-> EmptyMap, catching |-> FALSE,
  nonce |-> 0, responses |-> EmptyMap, out |-> <<>>, replies |-> <<>>,
  incarnation |-> inc, app |-> 0, applied |-> <<>>, results |-> <<>>,
  assertionFailed |-> FALSE, evidence |-> EmptyMap,
  selfMarks |-> {}, quorumMarks |-> {}, installMarks |-> {}, acceptMarks |-> {}]
\* lib.rs:292-300; Clients is a finite supply of distinct lifetime identities.
NewClient == [view |-> 0, next |-> 0, pending |-> Nil, out |-> <<>>]
Begin(s) == [s EXCEPT !.selfMarks={}, !.quorumMarks={}, !.installMarks={}, !.acceptMarks={}]
IsPrimary(i,s) == i=Primary(s.view)        \* lib.rs:1422-1428
Ready(i) == life[i]="Running" /\ phase[i]/="Persist"

\* lib.rs:1412-1413 and 1404-1408, preserve per-buffer order.
Send(s,i,j,w) == [s EXCEPT !.out=Append(@,Envelope(i,j,w,s.incarnation,<<>>))]
RECURSIVE SendOthersFrom(_,_,_,_)
SendOthersFrom(s,i,w,j) == IF j=N THEN s ELSE
    SendOthersFrom(IF j=i THEN s ELSE Send(s,i,j,w),i,w,j+1)
SendOthers(s,i,w) == SendOthersFrom(s,i,w,0)
SendReply(s,i,c,q,res) ==
    LET w == [Wire("Reply",s.view) EXCEPT !.client=c, !.request=q, !.result=res]
    IN [s EXCEPT !.replies=Append(@,Envelope(i,c,w,s.incarnation,<<>>))]
\* lib.rs:1381-1387. Prefix captured when acknowledgement is buffered.
SendPrepareOk(s,i) ==
    LET w == [Wire("PrepareOk",s.view) EXCEPT !.opn=Len(s.log)]
    IN [s EXCEPT !.out=Append(@,Envelope(i,Primary(s.view),w,s.incarnation,s.log))]
\* lib.rs:1390-1401.
SendGetState(s,i,k) == Send(s,i,Primary(s.view),[Wire("GetState",s.view) EXCEPT !.opn=k])
\* lib.rs:1083-1090.
SendStartView(s,i,j) == Send(s,i,j,[Wire("StartView",s.view) EXCEPT
    !.log=s.log, !.opn=Len(s.log), !.commit=s.commit])
\* lib.rs:1208-1214.
SendRecovery(s,i) == SendOthers(s,i,[Wire("Recovery",s.view) EXCEPT !.nonce=s.nonce])
\* lib.rs:994-997.
ClearViewChange(s) == [s EXCEPT !.svc={}, !.dvcSent=FALSE, !.dvc=EmptyMap]
\* lib.rs:1114-1121. Do not reset attempts here.
EnterNormal(s) == ClearViewChange([s EXCEPT !.status="Normal", !.lastNormal=s.view,
    !.catching=FALSE, !.heard=TRUE, !.waiting=0, !.stable=0])
\* lib.rs:1291-1295. Saturating stable at threshold is an exact predicate quotient:
\* higher values only participate in >= PrimaryTimeout. Trace normalizes this field.
NoteStable(s) == [s EXCEPT !.stable=Min(@+1,PrimaryTimeout),
    !.attempts=IF s.stable+1>=PrimaryTimeout THEN 0 ELSE @]
WaitLimit(s) == PrimaryTimeout * (2 ^ Min(s.attempts,10)) \* lib.rs:1302-1305
WaitTick(s) == [s EXCEPT !.waiting=@+1]

\* lib.rs:1310-1318. An append overwrites the client's entry even for older requests.
AppendToLog(s,e) == [s EXCEPT !.log=Append(@,e),
    !.table=PutMap(@,e.client,[request |-> e.request, reply |-> Nil])]
RECURSIVE AppendEntries(_,_,_)
AppendEntries(s,lg,k) == IF k>Len(lg) THEN s ELSE AppendEntries(AppendToLog(s,lg[k]),lg,k+1)
\* lib.rs:1324-1344. Only the final entry for each client survives the loop;
\* cached result is copied only for an already committed matching request.
RebuiltTable(s,lg) ==
    LET cs == {lg[k].client : k \in 1..Len(lg)}
    IN [c \in cs |-> LET k == MaxSet({j \in 1..Len(lg) : lg[j].client=c})
                         e == lg[k]
                     IN [request |-> e.request,
                         reply |-> IF k<=s.commit /\ c \in DOMAIN s.table
                                    THEN IF s.table[c].request=e.request
                                         THEN s.table[c].reply ELSE Nil
                                    ELSE Nil]]
InstallLog(s,lg,path) ==
    IF Len(lg)<s.commit THEN [s EXCEPT !.assertionFailed=TRUE]
    ELSE [s EXCEPT !.log=lg, !.table=RebuiltTable(s,lg),
      !.installMarks=@ \cup {[view |-> s.view, path |-> path, log |-> lg,
                              oldApplied |-> s.applied]}]
\* lib.rs:1362-1376, apply actual current application state, then advance commit,
\* conditionally cache, then optionally buffer a reply (1349-1355).
CommitOp(s,i,reply) ==
    IF s.commit>=Len(s.log) THEN [s EXCEPT !.assertionFailed=TRUE]
    ELSE LET e == s.log[s.commit+1]
             res == ApplyResult(s.app,e.input)
             a == [s EXCEPT !.app=ApplyValue(s.app,e.input), !.commit=@+1,
                   !.applied=Append(@,e), !.results=Append(@,res)]
             b == IF e.client \in DOMAIN a.table
                  THEN IF a.table[e.client].request=e.request
                       THEN [a EXCEPT !.table[e.client].reply=res] ELSE a
                  ELSE a
         IN IF reply THEN SendReply(b,i,e.client,e.request,res) ELSE b
RECURSIVE CommitUpTo(_,_,_,_)
CommitUpTo(s,i,k,reply) ==
    IF s.assertionFailed \/ s.commit>=k THEN s
    ELSE CommitUpTo(CommitOp(s,i,reply),i,k,reply)
\* lib.rs:684 and 1073-1075. Ghost evidence records the real self-ack site only.
RegisterSelf(s,i,k) == [s EXCEPT !.acks=PutMap(@,k,{i}),
    !.evidence=PutMap(@,k,{Ack(i,s,k)}), !.selfMarks=@ \cup {Ack(i,s,k)}]
RECURSIVE RegisterSuffix(_,_,_)
RegisterSuffix(s,i,k) == IF k>Len(s.log) THEN s ELSE RegisterSuffix(RegisterSelf(s,i,k),i,k+1)

\* lib.rs:1043-1080. BTreeMap's ascending iterator and max_by_key break ties
\* in favor of the LAST equal maximum (largest replica ID).
BestDVC(d) == CHOOSE j \in DOMAIN d : \A k \in DOMAIN d :
  \/ d[j].last>d[k].last
  \/ /\ d[j].last=d[k].last
     /\ \/ Len(d[j].log)>Len(d[k].log)
        \/ /\ Len(d[j].log)=Len(d[k].log) /\ j>=k
RecordDoViewChange(s,i,j,m) ==
    LET a == [s EXCEPT !.dvc=PutMap(@,j,[last |-> m.last, log |-> m.log, commit |-> m.commit])]
    IN IF Cardinality(DOMAIN a.dvc)<Quorum THEN a
       ELSE LET best == a.dvc[BestDVC(a.dvc)]
                k == MaxSet({a.dvc[n].commit : n \in DOMAIN a.dvc})
                b == InstallLog(a,best.log,"DoViewChange")
                c == CommitUpTo(b,i,k,TRUE)
                d == EnterNormal(c)
                e == RegisterSuffix([d EXCEPT !.acks=EmptyMap, !.evidence=EmptyMap],i,d.commit+1)
            IN SendOthers(e,i,[Wire("StartView",e.view) EXCEPT
                  !.log=e.log, !.opn=Len(e.log), !.commit=e.commit])
\* lib.rs:1015-1037. Primary self-record is synchronous, not a network step.
SendDoViewChange(s,i) ==
    LET m == [Wire("DoViewChange",s.view) EXCEPT !.last=s.lastNormal,
                !.log=s.log, !.opn=Len(s.log), !.commit=s.commit]
    IN IF IsPrimary(i,s) THEN RecordDoViewChange(s,i,i,m)
       ELSE Send(s,i,Primary(s.view),m)
\* lib.rs:1001-1010.
MaybeSendDoViewChange(s,i) ==
    IF s.status/="ViewChange" \/ s.catching \/ s.dvcSent THEN s
    ELSE IF Cardinality(s.svc)<N \div 2 THEN s
    ELSE SendDoViewChange([s EXCEPT !.dvcSent=TRUE],i)
\* lib.rs:971-991. attempts is saturated at 10, which is the sole timer-use cap;
\* reset behavior remains unchanged. This excludes arithmetic overflow (brief §3.2).
StartViewChange(s,i,v) ==
    LET a == ClearViewChange([s EXCEPT !.view=v, !.status="ViewChange",
                !.catching=FALSE, !.waiting=0,
                !.attempts=IF s.status="ViewChange" THEN Min(@+1,10) ELSE @])
        b == SendOthers(a,i,Wire("StartViewChange",v))
    IN MaybeSendDoViewChange(b,i)
\* lib.rs:1095-1108. Uncommitted suffix is retained until NewState arrives.
CatchUpWithView(s,i,v) ==
    IF s.view=v /\ s.catching THEN s
    ELSE LET a == ClearViewChange([s EXCEPT !.view=v, !.status="ViewChange",
                                    !.catching=TRUE, !.waiting=0])
         IN SendGetState(a,i,a.commit)
\* lib.rs:898-900.
StateTransfer(s,i) == SendGetState([s EXCEPT !.status="StateTransfer"],i,Len(s.log))
\* lib.rs:795-812, returning both the changed state and boolean result.
AcceptFromPrimary(s,i,v) ==
    IF v<s.view THEN [state |-> s, accepted |-> FALSE]
    ELSE IF v>s.view THEN [state |-> CatchUpWithView(s,i,v), accepted |-> FALSE]
    ELSE LET a == [s EXCEPT !.heard=TRUE]
         IN IF a.status="ViewChange" THEN [state |-> CatchUpWithView(a,i,v), accepted |-> FALSE]
            ELSE [state |-> a, accepted |-> a.status="Normal" /\ ~IsPrimary(i,a)]

\* lib.rs:646-693, three separate request branches (reject, cached reply, append).
OnRequest(s,i,m) ==
    IF ~IsPrimary(i,s) \/ s.status/="Normal" THEN s
    ELSE LET e == m.entry
         IN IF e.client \in DOMAIN s.table /\ e.request<=s.table[e.client].request
            THEN IF e.request=s.table[e.client].request /\ s.table[e.client].reply/=Nil
                 THEN SendReply(s,i,e.client,e.request,s.table[e.client].reply) ELSE s
            ELSE LET appended == AppendToLog(s,e)
                     accepted == [appended EXCEPT !.acceptMarks=@ \cup {
                         [node |-> i, incarnation |-> s.incarnation, view |-> s.view,
                          slot |-> Len(s.log)+1, entry |-> e]}]
                     a == RegisterSelf(accepted,i,Len(s.log)+1)
                 IN SendOthers(a,i,[Wire("Prepare",a.view) EXCEPT
                     !.entry=e, !.opn=Len(a.log), !.commit=a.commit])
\* lib.rs:701-730, accept side effects precede gap/append/duplicate handling.
OnPrepare(s,i,m) ==
    LET a == AcceptFromPrimary(s,i,m.view)
    IN IF ~a.accepted THEN a.state
       ELSE IF m.opn>Len(a.state.log)+1 THEN StateTransfer(a.state,i)
       ELSE LET b == IF m.opn=Len(a.state.log)+1 THEN AppendToLog(a.state,m.entry) ELSE a.state
                c == CommitUpTo(b,i,Min(m.commit,Len(b.log)),FALSE)
            IN SendPrepareOk(c,i)
\* lib.rs:737-767. Count IDs once, require exactly quorum after a NEW insert.
\* Received proof is only evidence; neither equal-prefix nor incarnation is a guard.
OnPrepareOk(s,i,e) ==
    LET m == e.wire
        k == m.opn
    IN IF m.view/=s.view \/ ~IsPrimary(i,s) \/ s.status/="Normal" THEN s
       ELSE IF k<=s.commit \/ k \notin DOMAIN s.acks THEN s
       ELSE IF e.src \in s.acks[k] THEN s
       ELSE LET vote == [node |-> e.src, incarnation |-> e.incarnation,
                         view |-> m.view, slot |-> k, prefix |-> e.proof]
                a == [s EXCEPT !.acks[k]=@ \cup {e.src}, !.evidence[k]=@ \cup {vote}]
            IN IF Cardinality(a.acks[k])/=Quorum THEN a
               ELSE LET b == [a EXCEPT !.quorumMarks=@ \cup {
                          [view |-> a.view, slot |-> k, prefix |-> Prefix(a.log,k),
                           votes |-> a.evidence[k]]}]
                        c == CommitUpTo(b,i,k,TRUE)
                        keep == {j \in DOMAIN c.acks : j>k}
                    IN [c EXCEPT !.acks=Restrict(@,keep), !.evidence=Restrict(@,keep)]
\* lib.rs:776-784.
OnCommit(s,i,m) ==
    LET a == AcceptFromPrimary(s,i,m.view)
    IN IF ~a.accepted THEN a.state
       ELSE IF m.commit>Len(a.state.log) THEN StateTransfer(a.state,i)
       ELSE CommitUpTo(a.state,i,m.commit,FALSE)
\* lib.rs:818-837. Intentionally NO is_primary guard: source accepts on any Normal replica.
OnGetState(s,i,e) ==
    LET m == e.wire
    IN IF s.status/="Normal" \/ m.view/=s.view \/ m.opn>Len(s.log) THEN s
       ELSE Send(s,i,e.src,[Wire("NewState",m.view) EXCEPT
           !.log=SubSeq(s.log,m.opn+1,Len(s.log)), !.start=m.opn,
           !.opn=Len(s.log), !.commit=s.commit])
\* lib.rs:850-854 shared preamble; 856-874 same-view append path.
OnNewStateTransfer(s,i,m) ==
    IF m.start>Len(s.log) \/ m.opn<=Len(s.log) THEN s
    ELSE LET a == AppendEntries(s,m.log,Len(s.log)-m.start+1)
             b == CommitUpTo(a,i,m.commit,FALSE)
         IN SendPrepareOk([b EXCEPT !.status="Normal"],i)
\* lib.rs:875-889 cross-view replacement path, exact offset = local commit.
OnNewStateCatchUp(s,i,m) ==
    IF m.start/=s.commit THEN s
    ELSE LET a == InstallLog(s,Prefix(s.log,m.start) \o m.log,"NewState")
             b == CommitUpTo(a,i,m.commit,FALSE)
         IN SendPrepareOk(EnterNormal(b),i)
OnNewState(s,i,m) ==
    IF m.view/=s.view THEN s
    ELSE IF Len(m.log)/=m.opn-m.start THEN [s EXCEPT !.assertionFailed=TRUE]
    ELSE LET a == [s EXCEPT !.heard=TRUE]
         IN CASE a.status="StateTransfer" -> OnNewStateTransfer(a,i,m)
              [] a.status="ViewChange" /\ a.catching -> OnNewStateCatchUp(a,i,m)
              [] OTHER -> a

\* lib.rs:906-921, higher-view adoption before inserting sender.
OnStartViewChange(s,i,e) ==
    LET m == e.wire
    IN IF m.view<s.view THEN s
       ELSE IF m.view=s.view /\ s.status/="ViewChange"
            THEN IF s.status="Normal" /\ IsPrimary(i,s) THEN SendStartView(s,i,e.src) ELSE s
       ELSE LET a == IF m.view>s.view THEN StartViewChange(s,i,m.view) ELSE s
            IN MaybeSendDoViewChange([a EXCEPT !.svc=@ \cup {e.src}],i)
\* lib.rs:926-942. Same-view non-Normal path need NOT be ViewChange in the code.
OnDoViewChange(s,i,e) ==
    LET m == e.wire
    IN IF m.view<s.view \/ Primary(m.view)/=i THEN s
       ELSE IF m.view=s.view /\ s.status="Normal" THEN SendStartView(s,i,e.src)
       ELSE LET a == IF m.view>s.view THEN StartViewChange(s,i,m.view) ELSE s
            IN RecordDoViewChange(a,i,e.src,m)
\* lib.rs:948-967, exact same-view ViewChange gate; no invented role gate.
OnStartView(s,i,m) ==
    IF m.view<s.view \/ (m.view=s.view /\ s.status/="ViewChange") THEN s
    ELSE LET a == InstallLog([s EXCEPT !.view=m.view],m.log,"StartView")
             b == EnterNormal(CommitUpTo(a,i,m.commit,FALSE))
         IN SendPrepareOk([b EXCEPT !.acks=EmptyMap, !.evidence=EmptyMap],i)
\* lib.rs:1131-1149. Higher persisted floor triggers view change and NO response.
OnRecovery(s,i,e) ==
    LET m == e.wire
    IN IF m.view>s.view /\ s.status/="Recovering" THEN StartViewChange(s,i,m.view)
       ELSE IF s.status/="Normal" THEN s
       ELSE Send(s,i,e.src,[Wire("RecoveryResponse",s.view) EXCEPT
             !.nonce=m.nonce, !.hasState=IsPrimary(i,s),
             !.log=IF IsPrimary(i,s) THEN s.log ELSE <<>>,
             !.commit=IF IsPrimary(i,s) THEN s.commit ELSE 0])
\* lib.rs:1159-1205. Map overwrites by sender, including older response views;
\* a fresh nonce, quorum of OTHER replica IDs, latest view floor and primary state.
OnRecoveryResponse(s,i,e) ==
    LET m == e.wire
    IN IF s.status/="Recovering" \/ m.nonce/=s.nonce THEN s
       ELSE LET a == [s EXCEPT !.responses=PutMap(@,e.src,m)]
            IN IF Cardinality(DOMAIN a.responses)<Quorum THEN a
               ELSE LET v == MaxSet({a.responses[j].view : j \in DOMAIN a.responses})
                        p == Primary(v)
                    IN IF v<a.view \/ p \notin DOMAIN a.responses THEN a
                       ELSE IF ~a.responses[p].hasState \/ a.responses[p].view/=v THEN a
                       ELSE LET m2 == a.responses[p]
                                b == [a EXCEPT !.responses=EmptyMap, !.view=v]
                                c == InstallLog(b,m2.log,"Recovery")
                            IN EnterNormal(CommitUpTo(c,i,m2.commit,FALSE))

\* lib.rs:1233-1253. Heartbeat precedes retransmitted prepares.
RECURSIVE ResendPrepares(_,_,_)
ResendPrepares(s,i,k) == IF k>Len(s.log) THEN s ELSE
    ResendPrepares(SendOthers(s,i,[Wire("Prepare",s.view) EXCEPT
       !.opn=k, !.entry=s.log[k], !.commit=s.commit]),i,k+1)
OnIdlePrimary(s,i) ==
    LET a == NoteStable(s)
        b == SendOthers(a,i,[Wire("Commit",a.view) EXCEPT !.commit=a.commit])
    IN ResendPrepares(b,i,b.commit+1)
\* lib.rs:1256-1268. State-transfer retry happens BEFORE timer processing.
OnIdleBackup(s,i) ==
    LET a == IF s.status="StateTransfer" THEN StateTransfer(s,i) ELSE s
        b == [a EXCEPT !.heard=FALSE]
    IN IF a.heard THEN NoteStable([b EXCEPT !.waiting=0])
       ELSE LET c == WaitTick([b EXCEPT !.stable=0])
            IN IF c.waiting>=WaitLimit(c) THEN StartViewChange(c,i,c.view+1) ELSE c
\* lib.rs:1270-1283. DoViewChange re-send may self-record and complete a view.
OnIdleViewChange(s,i) ==
    LET a == WaitTick(s)
    IN IF a.waiting>=WaitLimit(a) THEN StartViewChange(a,i,a.view+1)
       ELSE IF a.catching THEN SendGetState(a,i,a.commit)
       ELSE LET b == SendOthers(a,i,Wire("StartViewChange",a.view))
            IN IF b.dvcSent THEN SendDoViewChange(b,i) ELSE b
OnIdle(s,i) == CASE s.status="Normal" /\ IsPrimary(i,s) -> OnIdlePrimary(s,i)
                   [] s.status="Recovering" -> SendRecovery(s,i) \* lib.rs:1255
                   [] s.status="ViewChange" -> OnIdleViewChange(s,i)
                   [] OTHER -> OnIdleBackup(s,i)

\* lib.rs:528-641, recovering dispatch filter comes before variant dispatch.
OnMessage(s,i,e) ==
    IF s.status="Recovering" /\ e.wire.kind/="RecoveryResponse" THEN s
    ELSE CASE e.wire.kind="Request" -> OnRequest(s,i,e.wire)
           [] e.wire.kind="Prepare" -> OnPrepare(s,i,e.wire)
           [] e.wire.kind="PrepareOk" -> OnPrepareOk(s,i,e)
           [] e.wire.kind="Commit" -> OnCommit(s,i,e.wire)
           [] e.wire.kind="GetState" -> OnGetState(s,i,e)
           [] e.wire.kind="NewState" -> OnNewState(s,i,e.wire)
           [] e.wire.kind="StartViewChange" -> OnStartViewChange(s,i,e)
           [] e.wire.kind="DoViewChange" -> \* lib.rs:609 before handler dispatch
                IF Len(e.wire.log)/=e.wire.opn THEN [s EXCEPT !.assertionFailed=TRUE]
                ELSE OnDoViewChange(s,i,e)
           [] e.wire.kind="StartView" -> \* lib.rs:623 before handler dispatch
                IF Len(e.wire.log)/=e.wire.opn THEN [s EXCEPT !.assertionFailed=TRUE]
                ELSE OnStartView(s,i,e.wire)
           [] e.wire.kind="Recovery" -> OnRecovery(s,i,e)
           [] e.wire.kind="RecoveryResponse" -> OnRecoveryResponse(s,i,e)

\* S1-S2 observation only: never reject a transition based on an oracle.
\* Applied histories are append-only WITHIN each incarnation, retained across reboot.
Observe(i,s) ==
  /\ acceptanceHistory'=acceptanceHistory \cup s.acceptMarks
  /\ ackHistory'=ackHistory \cup s.selfMarks
  /\ quorumHistory'=quorumHistory \cup s.quorumMarks
  /\ installedViewHistory'=installedViewHistory \cup
       {[node |-> i, incarnation |-> s.incarnation, data |-> x] : x \in s.installMarks}
  /\ appliedByIncarnation'=PutMap(appliedByIncarnation,<<i,s.incarnation>>,s.applied)
  /\ historicalPrefixes'=historicalPrefixes \cup {s.applied,Prefix(s.log,s.commit)}
  /\ logicalHistory'=IF Len(s.applied)>Len(logicalHistory)
                     THEN logicalHistory \o SubSeq(s.applied,Len(logicalHistory)+1,Len(s.applied))
                     ELSE logicalHistory
  /\ primaryHistory'=IF s.status="Normal" /\ IsPrimary(i,s)
                     THEN primaryHistory \cup {[node |-> i, view |-> s.view, log |-> s.log]}
                     ELSE primaryHistory

\* lib.rs:528 and 1233; caller contract lib.rs:14-18 requires a persist phase.
ReplicaOnMessage(i,e) ==
  /\ Ready(i) /\ e \in DOMAIN network /\ e.dst=i
  /\ LET s == OnMessage(Begin(r[i]),i,e)
     IN /\ r'=[r EXCEPT ![i]=s] /\ Observe(i,s)
  /\ phase'=[phase EXCEPT ![i]="Persist"]
  /\ network'=RemoveOne(network,e)
  /\ UNCHANGED <<durableView,life,incarnation,clientVars,replyChannel,released>>
ReplicaOnIdle(i) ==
  /\ Ready(i)
  /\ LET s == OnIdle(Begin(r[i]),i)
     IN /\ r'=[r EXCEPT ![i]=s] /\ Observe(i,s)
  /\ phase'=[phase EXCEPT ![i]="Persist"]
  /\ UNCHANGED <<durableView,life,incarnation,clientVars,channelVars>>

\* lib.rs:14-18; examples/kvstore/main.rs:749. Atomic durable publication abstraction.
PersistView(i) ==
  /\ life[i]="Running" /\ phase[i]="Persist"
  /\ durableView'=[durableView EXCEPT ![i]=r[i].view]
  /\ phase'=[phase EXCEPT ![i]="Release"]
  /\ UNCHANGED <<r,life,incarnation,clientVars,channelVars,historyVars>>
\* lib.rs:1468-1469, one released message; remaining outbox is volatile.
ReleaseMessage(i) ==
  /\ Ready(i) /\ r[i].out/= <<>> /\ durableView[i]>=r[i].view
  /\ LET e == Head(r[i].out)
     IN /\ network'=AddBag(network,<<e>>)
        /\ released'=released \cup {e}
        /\ ackHistory'=IF e.wire.kind="PrepareOk" THEN ackHistory \cup {
             [node |-> e.src, incarnation |-> e.incarnation, view |-> e.wire.view,
              slot |-> e.wire.opn, prefix |-> e.proof]} ELSE ackHistory
  /\ r'=[r EXCEPT ![i].out=Tail(@)]
  /\ UNCHANGED <<durableView,life,phase,incarnation,clientVars,replyChannel,
       quorumHistory,installedViewHistory,appliedByIncarnation,historicalPrefixes,logicalHistory,primaryHistory,acceptanceHistory>>
\* lib.rs:1473-1474. Replies have independent delay, duplication, and loss.
ReleaseReply(i) ==
  /\ Ready(i) /\ r[i].replies/= <<>> /\ durableView[i]>=r[i].view
  /\ LET e == Head(r[i].replies)
     IN /\ replyChannel'=AddBag(replyChannel,<<e>>) /\ released'=released \cup {e}
  /\ r'=[r EXCEPT ![i].replies=Tail(@)]
  /\ UNCHANGED <<durableView,life,phase,incarnation,clientVars,network,historyVars>>

\* S1 retained-state suspension differs from state-losing reboot; lib.rs:14-18,505-524.
Pause(i) == /\ life[i]="Running" /\ life'=[life EXCEPT ![i]="Paused"]
            /\ UNCHANGED <<r,durableView,phase,incarnation,clientVars,channelVars,historyVars>>
Resume(i) == /\ life[i]="Paused" /\ life'=[life EXCEPT ![i]="Running"]
             /\ UNCHANGED <<r,durableView,phase,incarnation,clientVars,channelVars,historyVars>>
Crash(i) ==
  /\ life[i]/="Down"
  /\ life'=[life EXCEPT ![i]="Down"]
  /\ r'=[r EXCEPT ![i]=NewReplica(incarnation[i])]
  /\ phase'=[phase EXCEPT ![i]="Release"]
  /\ UNCHANGED <<durableView,incarnation,clientVars,channelVars,historyVars>>
Recover(i) ==
  /\ life[i]="Down"
  /\ LET inc == incarnation[i]+1
         s == SendRecovery([NewReplica(inc) EXCEPT !.status="Recovering",
                 !.view=durableView[i], !.lastNormal=durableView[i], !.nonce=inc],i)
     IN /\ r'=[r EXCEPT ![i]=s] /\ Observe(i,s)
  /\ incarnation'=[incarnation EXCEPT ![i]=@+1]
  /\ life'=[life EXCEPT ![i]="Running"] /\ phase'=[phase EXCEPT ![i]="Persist"]
  /\ UNCHANGED <<durableView,clientVars,channelVars>>

\* lib.rs:312-326 with the explicit owner discipline lib.rs:274-277.
ClientOnRequest(c,x) ==
  /\ c \notin retiredClients /\ clients[c].pending=Nil /\ x \in Inputs
  /\ LET e == Entry(c,clients[c].next,x)
         m == Envelope(c,Primary(clients[c].view),[Wire("Request",0) EXCEPT !.entry=e],0,<<>>)
     IN /\ clients'=[clients EXCEPT ![c].next=@+1, ![c].pending=e, ![c].out=Append(@,m)]
        /\ requestInput'=PutMap(requestInput,Key(e),x)
  /\ UNCHANGED <<replicaVars,retiredClients,acceptedReplies,channelVars,historyVars>>
\* lib.rs:353-369, every configured replica including primary.
ClientOnIdle(c) ==
  /\ c \notin retiredClients /\ clients[c].pending/=Nil
  /\ LET e == clients[c].pending
         ms == [j \in 1..N |-> Envelope(c,j-1,[Wire("Request",0) EXCEPT !.entry=e],0,<<>>)]
     IN clients'=[clients EXCEPT ![c].out=@ \o ms]
  /\ UNCHANGED <<replicaVars,retiredClients,requestInput,acceptedReplies,channelVars,historyVars>>
\* lib.rs:374-375, single-item publication; distinct from client invocation.
ClientDrain(c) ==
  /\ c \notin retiredClients /\ clients[c].out/= <<>>
  /\ LET e == Head(clients[c].out)
     IN /\ network'=AddBag(network,<<e>>) /\ released'=released \cup {e}
  /\ clients'=[clients EXCEPT ![c].out=Tail(@)]
  /\ UNCHANGED <<replicaVars,retiredClients,requestInput,acceptedReplies,replyChannel,historyVars>>
\* lib.rs:334-347. Owner routes by client_id before Client::on_reply (result not its argument).
ClientOnReply(c,e) ==
  /\ c \notin retiredClients /\ e \in DOMAIN replyChannel /\ e.dst=c
  /\ LET pending == clients[c].pending
         accept == IF pending=Nil THEN FALSE ELSE pending.request=e.wire.request
     IN /\ clients'=[clients EXCEPT ![c].view=Max(@,e.wire.view),
                ![c].pending=IF accept THEN Nil ELSE @]
        /\ acceptedReplies'=IF accept THEN acceptedReplies \cup {e} ELSE acceptedReplies
  /\ replyChannel'=RemoveOne(replyChannel,e)
  /\ UNCHANGED <<replicaVars,retiredClients,requestInput,network,released,historyVars>>
\* lib.rs:29-31. A restart retires identity c; a different unused Clients value
\* is the new lifetime. Old invocations and authentic messages remain historical.
ClientRetire(c) ==
  /\ c \notin retiredClients
  /\ retiredClients'=retiredClients \cup {c}
  /\ clients'=[clients EXCEPT ![c].pending=Nil, ![c].out = <<>>]
  /\ UNCHANGED <<replicaVars,requestInput,acceptedReplies,channelVars,historyVars>>

\* S1-S3 authentic transport, lib.rs:6-12. Replay NEVER invents an un-emitted packet.
LoseMessage(e) == /\ e \in DOMAIN network /\ network'=RemoveOne(network,e)
  /\ UNCHANGED <<replicaVars,clientVars,replyChannel,released,historyVars>>
LoseReply(e) == /\ e \in DOMAIN replyChannel /\ replyChannel'=RemoveOne(replyChannel,e)
  /\ UNCHANGED <<replicaVars,clientVars,network,released,historyVars>>
ReplayMessage(e) == /\ e \in released /\ e.wire.kind/="Reply"
  /\ network'=AddBag(network,<<e>>)
  /\ UNCHANGED <<replicaVars,clientVars,replyChannel,released,historyVars>>
ReplayReply(e) == /\ e \in released /\ e.wire.kind="Reply"
  /\ replyChannel'=AddBag(replyChannel,<<e>>)
  /\ UNCHANGED <<replicaVars,clientVars,network,released,historyVars>>

Init ==
  /\ r=[i \in Server |-> NewReplica(0)] /\ durableView=[i \in Server |-> 0]
  /\ life=[i \in Server |-> "Running"] /\ phase=[i \in Server |-> "Release"]
  /\ incarnation=[i \in Server |-> 0]
  /\ clients=[c \in Clients |-> NewClient] /\ retiredClients={}
  /\ requestInput=EmptyMap /\ acceptedReplies={}
  /\ network=EmptyBag /\ replyChannel=EmptyBag /\ released={}
  /\ ackHistory={} /\ quorumHistory={} /\ installedViewHistory={}
  /\ appliedByIncarnation=[k \in {<<i,0>> : i \in Server} |-> <<>>]
  /\ historicalPrefixes={<<>>} /\ logicalHistory = <<>> /\ primaryHistory={} /\ acceptanceHistory={}
Next ==
  \/ \E i \in Server :
       \/ \E e \in DOMAIN network : ReplicaOnMessage(i,e)
       \/ ReplicaOnIdle(i) \/ PersistView(i) \/ ReleaseMessage(i) \/ ReleaseReply(i)
       \/ Pause(i) \/ Resume(i) \/ Crash(i) \/ Recover(i)
  \/ \E c \in Clients :
       \/ \E x \in Inputs : ClientOnRequest(c,x)
       \/ ClientOnIdle(c) \/ ClientDrain(c) \/ ClientRetire(c)
       \/ \E e \in DOMAIN replyChannel : ClientOnReply(c,e)
  \/ \E e \in DOMAIN network : LoseMessage(e)
  \/ \E e \in DOMAIN replyChannel : LoseReply(e)
  \/ \E e \in released : ReplayMessage(e) \/ ReplayReply(e)
Spec == Init /\ [][Next]_vars

\* Structural/core properties. No property is used to prune bad successors.
EntryOK(e) == /\ e.client \in Clients /\ e.request \in Nat /\ e.input \in Inputs
TypeOK ==
  /\ DOMAIN r=Server /\ durableView \in [Server -> Nat]
  /\ life \in [Server -> {"Running","Paused","Down"}]
  /\ phase \in [Server -> {"Persist","Release"}] /\ incarnation \in [Server -> Nat]
  /\ DOMAIN clients=Clients /\ retiredClients \subseteq Clients
  /\ IsABag(network) /\ IsABag(replyChannel)
  /\ \A i \in Server :
       /\ r[i].status \in {"Normal","StateTransfer","ViewChange","Recovering"}
       /\ r[i].view \in Nat /\ r[i].lastNormal \in Nat /\ r[i].commit \in Nat
       /\ r[i].log \in Seq([client : Clients, request : Nat, input : Inputs])
       /\ r[i].app \in Values /\ r[i].waiting \in Nat /\ r[i].attempts \in 0..10
       /\ r[i].stable \in 0..PrimaryTimeout /\ r[i].heard \in BOOLEAN
       /\ r[i].catching \in BOOLEAN /\ r[i].dvcSent \in BOOLEAN
       /\ DOMAIN r[i].acks \subseteq (Nat \ {0})
       /\ \A k \in DOMAIN r[i].acks : r[i].acks[k] \subseteq Server
       /\ DOMAIN r[i].table \subseteq Clients
       /\ r[i].svc \subseteq Server /\ DOMAIN r[i].dvc \subseteq Server
       /\ DOMAIN r[i].responses \subseteq Server
CommitBounds == \A i \in Server : 0<=r[i].commit /\ r[i].commit<=Len(r[i].log)
ImplementationAssertions == \A i \in Server : ~r[i].assertionFailed
PublicationOrder == \A i \in Server :
  life[i]/="Down" => (durableView[i]<=r[i].view /\
    (phase[i]="Release" => durableView[i]=r[i].view))
PrimaryForView ==
  /\ \A h \in primaryHistory : h.node=Primary(h.view)
  /\ \A a,b \in primaryHistory : a.view=b.view => Compatible(a.log,b.log)
HistoricalPrefixAgreement == \A h \in historicalPrefixes : IsPrefix(h,logicalHistory)
ApplicationMatchesHistory ==
  /\ \A i \in Server :
       /\ r[i].applied=Prefix(r[i].log,r[i].commit)
       /\ r[i].app=ReplayState(r[i].applied)
       /\ r[i].results=ReplayResults(r[i].applied)
  /\ \A k \in DOMAIN appliedByIncarnation : IsPrefix(appliedByIncarnation[k],logicalHistory)
LogicalRequestOnce == \A h \in historicalPrefixes :
    \A j,k \in 1..Len(h) : Key(h[j])=Key(h[k]) => j=k
ReplyCorrect(e) ==
    LET key == <<e.wire.client,e.wire.request>>
    IN /\ key \in DOMAIN requestInput
       /\ \E k \in 1..Len(logicalHistory) :
            /\ Key(logicalHistory[k])=key
            /\ logicalHistory[k].input=requestInput[key]
            /\ e.wire.result=ReplayResults(logicalHistory)[k]
ReplySoundness ==
  /\ \A e \in acceptedReplies : ReplyCorrect(e)
  /\ \A e \in released : e.wire.kind="Reply" => ReplyCorrect(e)
  /\ \A i \in Server : \A c \in DOMAIN r[i].table :
       r[i].table[c].reply/=Nil =>
         \E k \in 1..r[i].commit :
           /\ Key(r[i].log[k]) = <<c,r[i].table[c].request>>
           /\ r[i].table[c].reply=ReplayResults(r[i].log)[k]
\* S1 certificates are derived from emissions (including actual self-ack sites).
\* Quorum identification counts IDs, NOT equality of prefixes. Agreement is checked.
EmissionCertificates == {a \in ackHistory : a.slot>0 /\
    Cardinality({b.node : b \in {x \in ackHistory : x.view=a.view /\ x.slot>=a.slot}})>=Quorum}
SameViewAckAgreement == \A a,b \in ackHistory :
    a.view=b.view => Compatible(a.prefix,b.prefix)
Eligible == {i \in Server : life[i]/="Down" /\ r[i].status/="Recovering"}
BestCurrent(q) == {j \in q : \A k \in q :
    r[j].lastNormal>r[k].lastNormal \/
    (r[j].lastNormal=r[k].lastNormal /\ Len(r[j].log)>=Len(r[k].log))}
ProtectedPrefixSurvives ==
  /\ SameViewAckAgreement
  /\ \A cert \in EmissionCertificates :
       /\ \A h \in historicalPrefixes : Compatible(cert.prefix,h)
       /\ \A i \in Eligible :
            r[i].lastNormal>cert.view => IsPrefix(cert.prefix,r[i].log)
       /\ \A q \in SUBSET Eligible : Cardinality(q)=Quorum =>
            \A best \in BestCurrent(q) : IsPrefix(cert.prefix,r[best].log)
  /\ \A cert \in quorumHistory :
       /\ Cardinality({v.node : v \in cert.votes})=Quorum
       /\ \A v \in cert.votes : v.view=cert.view /\ IsPrefix(cert.prefix,v.prefix)
  /\ \A h \in installedViewHistory : IsPrefix(h.data.oldApplied,h.data.log)
=============================================================================
