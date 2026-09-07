------------------------------ MODULE base ------------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

\* Category A. Implementation: 3ac0104a567092139534c9022205d02281a2da41.
\* Scope is modeling-brief.md Scenarios 1-5. One owner call is atomic;
\* persist and each output publication are separate transitions (Scenario 4).
\* No paper-only self-DVC rule, durable log, nonce reuse, or arbitrary corruption.
CONSTANTS Server, Clients, Values, PrimaryTimeout, FailureBudget,
          IntegrationMode, FullValue, PrefixValue
ASSUME /\ Server = 0..(Cardinality(Server)-1) /\ Cardinality(Server) >= 2
       /\ Clients /= {} /\ Server \cap Clients = {}
       /\ PrimaryTimeout >= 1 /\ FailureBudget >= 0
       /\ 2*FailureBudget < Cardinality(Server)
       /\ {FullValue, PrefixValue} \subseteq Values /\ FullValue /= PrefixValue

Empty == [x \in {} |-> x]
Min(a,b) == IF a < b THEN a ELSE b
Max(a,b) == IF a > b THEN a ELSE b
Maximum(s) == CHOOSE x \in s : \A y \in s : x >= y
Restrict(f,s) == [x \in s |-> f[x]]
Put(f,k,v) == [x \in DOMAIN f \cup {k} |-> IF x=k THEN v ELSE f[x]]
SeqSet(s) == {s[k] : k \in 1..Len(s)}
Prefix(s,n) == SubSeq(s,1,n)
Primary(v) == v % Cardinality(Server)  \* lib.rs:86-98
Quorum == Cardinality(Server) \div 2 + 1
Nil == "nil"                            \* Store::apply(None), main.rs:56-62
NoEntry == [client |-> -1, request |-> -1, op |-> [kind |-> "Get", value |-> Nil]]
Ops == {[kind |-> "Put", value |-> v] : v \in Values}
       \cup {[kind |-> "Get", value |-> Nil]}
RequestId(e) == <<e.client,e.request>>
ApplyValue(a,op) == IF op.kind="Put" THEN op.value ELSE a
ApplyResult(a,op) == IF op.kind="Put" THEN Nil ELSE a

\* A uniform message envelope. src is transport provenance, never a new guard.
\* Message payload fields follow lib.rs:142-270; Reply:124-131.
Msg(kind,src,dst,v) ==
 [kind |-> kind, src |-> src, dst |-> dst, view |-> v,
  opnum |-> 0, commit |-> 0, entry |-> NoEntry, log |-> <<>>,
  start |-> 0, lastNormal |-> 0, nonce |-> 0, hasState |-> FALSE, result |-> Nil]
Others(m,i) == LET ids == SelectSeq([j \in 1..Cardinality(Server) |-> j-1],
                                   LAMBDA j : j /= i)
              IN [k \in 1..Len(ids) |-> [m EXCEPT !.dst=ids[k]]]
Enqueue(s,ms) == [s EXCEPT !.messages = @ \o ms] \* lib.rs:1399-1417
Broadcast(s,m,i) == Enqueue(s,Others(m,i))
PrepareMsg(s,i,k) == [Msg("Prepare",i,0,s.view) EXCEPT
                        !.opnum=k, !.entry=s.log[k], !.commit=s.commit]
StartViewMsg(s,i,j) == [Msg("StartView",i,j,s.view) EXCEPT
                        !.log=s.log, !.opnum=Len(s.log), !.commit=s.commit]
DVCMsg(s,i) == [Msg("DoViewChange",i,Primary(s.view),s.view) EXCEPT
                        !.lastNormal=s.lastNormal, !.log=s.log,
                        !.opnum=Len(s.log), !.commit=s.commit]
RecoveryMsg(s,i) == [Msg("Recovery",i,0,s.view) EXCEPT !.nonce=s.nonce]
GetState(s,i,k) == Enqueue(s,<<[Msg("GetState",i,Primary(s.view),s.view)
                                     EXCEPT !.opnum=k]>>)
PrepareOK(s,i) == Enqueue(s,<<[Msg("PrepareOk",i,Primary(s.view),s.view)
                                     EXCEPT !.opnum=Len(s.log)]>>)

\* Local state: lib.rs:427-501. executed/install/error are observers for
\* Scenarios 1-4, not implementation guards. Timers stable/attempts are
\* saturated only where all future behavior is identical (1291-1305).
NewReplica ==
 [status |-> "Normal", view |-> 0, lastNormal |-> 0, log |-> <<>>, commit |-> 0,
  acks |-> Empty, table |-> Empty, heard |-> TRUE, waiting |-> 0,
  attempts |-> 0, stable |-> 0, svc |-> {}, dvcSent |-> FALSE, dvc |-> Empty,
  catching |-> FALSE, nonce |-> 0, responses |-> Empty,
  messages |-> <<>>, replies |-> <<>>, app |-> Nil, executed |-> <<>>,
  install |-> [kind |-> "none", view |-> 0, log |-> <<>>], error |-> ""]
ResetAudit(s) == [s EXCEPT !.install=[kind |-> "none",view |-> s.view,log |-> <<>>]]
ClearViewChange(s) == [s EXCEPT !.svc={}, !.dvcSent=FALSE, !.dvc=Empty]
EnterNormal(s) == ClearViewChange([s EXCEPT  \* lib.rs:1114-1121, keep backoff
 !.status="Normal", !.lastNormal=s.view, !.catching=FALSE,
 !.heard=TRUE, !.waiting=0, !.stable=0])
AppendToLog(s,e) == [s EXCEPT            \* lib.rs:1310-1318
 !.log=Append(@,e), !.table=Put(@,e.client,
                         [request |-> e.request,hasReply |-> FALSE,result |-> Nil])]
RECURSIVE AppendEntries(_,_)
AppendEntries(s,entries) == IF entries= <<>> THEN s
 ELSE AppendEntries(AppendToLog(s,Head(entries)),Tail(entries))

\* Preserve old application state and old matching cached replies exactly;
\* DO NOT assume the new log's committed prefix equals the old one.
\* lib.rs:1324-1345. An assertion failure is observable, never a disabled step.
InstallLog(s,lg,why) ==
 IF Len(lg)<s.commit THEN [s EXCEPT !.error="install_log length assertion"]
 ELSE LET cs == {e.client : e \in SeqSet(lg)}
          table == [c \in cs |->
            LET k == Maximum({k \in 1..Len(lg):lg[k].client=c})
                e == lg[k]
                keep == IF c \in DOMAIN s.table
                        THEN k<=s.commit /\ s.table[c].request=e.request
                             /\ s.table[c].hasReply ELSE FALSE
            IN [request |-> e.request,hasReply |-> keep,
                result |-> IF keep THEN s.table[c].result ELSE Nil]]
      IN [s EXCEPT !.log=lg, !.table=table,
                   !.install=[kind |-> why,view |-> s.view,log |-> lg]]

\* A complete commit loop is inside one synchronous on_message/on_idle call.
\* lib.rs:1349-1377; Store semantics examples/kvstore/main.rs:56-62.
CommitOp(s,i,reply) ==
 LET k == s.commit+1
     e == s.log[k]
     out == ApplyResult(s.app,e.op)
     r == [Msg("Reply",i,e.client,s.view) EXCEPT !.entry=[NoEntry EXCEPT !.client=e.client,!.request=e.request], !.result=out]
     tab == IF e.client \in DOMAIN s.table
            THEN IF s.table[e.client].request=e.request
                 THEN [s.table EXCEPT ![e.client].hasReply=TRUE,
                                       ![e.client].result=out]
                 ELSE s.table ELSE s.table
 IN [s EXCEPT !.commit=k, !.app=ApplyValue(s.app,e.op), !.table=tab,
     !.executed=Append(@,[pos |-> k,entry |-> e,result |-> out,view |-> s.view]),
     !.replies=IF reply THEN Append(@,r) ELSE @]
RECURSIVE CommitUpTo(_,_,_,_)
CommitUpTo(s,i,k,reply) ==
 IF k>Len(s.log) THEN [s EXCEPT !.error="commit_op log index assertion"]
 ELSE IF s.commit>=k THEN s ELSE CommitUpTo(CommitOp(s,i,reply),i,k,reply)

\* DVC selection: BTreeMap iteration + max_by_key selects LAST maximum,
\* hence highest replica id on an exact key tie (lib.rs:1043-1059).
\* The map can reach quorum WITHOUT self. Do not insert a synthetic self vote.
RecordDoViewChange(s,i,m) ==
 LET ds == Put(s.dvc,m.src,m)
     a == [s EXCEPT !.dvc=ds]
 IN IF Cardinality(DOMAIN ds)<Quorum THEN a
 ELSE LET latest == Maximum({ds[j].lastNormal:j \in DOMAIN ds})
          candidates == {j \in DOMAIN ds:ds[j].lastNormal=latest}
          longest == Maximum({Len(ds[j].log):j \in candidates})
          best == Maximum({j \in candidates:Len(ds[j].log)=longest})
          ck == Maximum({ds[j].commit:j \in DOMAIN ds})
          \* lib.rs:1066-1075: install, execute/reply, normal, new self acks.
          b == EnterNormal(CommitUpTo(InstallLog(a,ds[best].log,"DVC"),i,ck,TRUE))
          c == [b EXCEPT !.acks=[k \in (b.commit+1)..Len(b.log) |-> {i}]]
      IN Enqueue(c,Others(StartViewMsg(c,i,0),i)) \* lib.rs:1076-1080
SendDoViewChange(s,i) ==                \* lib.rs:1015-1037
 IF Primary(s.view)=i THEN RecordDoViewChange(s,i,DVCMsg(s,i))
 ELSE Enqueue(s,<<DVCMsg(s,i)>>)
MaybeSendDoViewChange(s,i) ==           \* lib.rs:1001-1010
 IF s.status/="ViewChange" \/ s.catching \/ s.dvcSent
    \/ Cardinality(s.svc)<Cardinality(Server)\div 2 THEN s
 ELSE SendDoViewChange([s EXCEPT !.dvcSent=TRUE],i)
StartViewChange(s,i,v) ==               \* lib.rs:971-991
 LET a == ClearViewChange([s EXCEPT
             !.attempts=IF s.status="ViewChange" THEN Min(@+1,10) ELSE @,
             !.view=v, !.status="ViewChange", !.catching=FALSE, !.waiting=0])
 IN MaybeSendDoViewChange(Broadcast(a,Msg("StartViewChange",i,0,v),i),i)
CatchUpWithView(s,i,v) ==               \* lib.rs:1095-1108
 IF s.view=v /\ s.catching THEN s
 ELSE GetState(ClearViewChange([s EXCEPT !.view=v,!.status="ViewChange",
                                           !.catching=TRUE,!.waiting=0]),i,s.commit)
StateTransfer(s,i) == GetState([s EXCEPT !.status="StateTransfer"],i,Len(s.log))

\* Branch-local functions; the action wrappers below expose divergent paths.
OnRequestResult(s,i,m) ==
 \* lib.rs:651-674: status/primary guard, stale, duplicate-pending/cached reply.
 IF Primary(s.view)/=i \/ s.status/="Normal" THEN s
 ELSE IF m.entry.client \in DOMAIN s.table /\
         m.entry.request<=s.table[m.entry.client].request
 THEN LET e == s.table[m.entry.client]
      IN IF m.entry.request=e.request /\ e.hasReply
         THEN [s EXCEPT !.replies=Append(@,[Msg("Reply",i,m.entry.client,s.view)
                            EXCEPT !.entry=[NoEntry EXCEPT !.client=m.entry.client,!.request=m.entry.request],!.result=e.result])] ELSE s
 \* lib.rs:677-693: append first, then self acknowledgement, then broadcast.
 ELSE LET a == AppendToLog(s,m.entry)
          b == [a EXCEPT !.acks=Put(@,Len(a.log),{i})]
      IN Broadcast(b,PrepareMsg(b,i,Len(b.log)),i)

AcceptFromPrimary(s,i,v) ==             \* lib.rs:795-812; includes side effects
 IF v<s.view THEN s
 ELSE IF v>s.view THEN CatchUpWithView(s,i,v)
 ELSE LET a == [s EXCEPT !.heard=TRUE]
      IN IF s.status="ViewChange" THEN CatchUpWithView(a,i,v) ELSE a
CanAccept(s,i,v) == v=s.view /\ s.status="Normal" /\ Primary(s.view)/=i
OnPrepareResult(s,i,m) ==
 LET a == AcceptFromPrimary(s,i,m.view)
 IN IF ~CanAccept(s,i,m.view) THEN a    \* lib.rs:708-710
 ELSE IF m.opnum>Len(s.log)+1 THEN StateTransfer(a,i) \* lib.rs:712-714
 ELSE LET b == IF m.opnum=Len(s.log)+1 THEN AppendToLog(a,m.entry) ELSE a
          \* lib.rs:716-727: duplicate does NOT compare or replace entry.
          c == CommitUpTo(b,i,Min(m.commit,Len(b.log)),FALSE)
      IN PrepareOK(c,i)                \* lib.rs:728-730
OnPrepareOkResult(s,i,m) ==
 \* lib.rs:743-755: exact view, primary, normal, ack map entry must exist.
 IF m.view/=s.view \/ Primary(s.view)/=i \/ s.status/="Normal"
    \/ m.opnum<=s.commit \/ m.opnum \notin DOMAIN s.acks THEN s
 ELSE LET old == s.acks[m.opnum]
          a == [s EXCEPT !.acks[m.opnum]=@ \cup {m.src}]
      \* lib.rs:756: insert FIRST, then require new participant and EXACT quorum.
      IN IF m.src \in old \/ Cardinality(a.acks[m.opnum])/=Quorum THEN a
         ELSE LET b == CommitUpTo(a,i,m.opnum,TRUE) \* lib.rs:759-765
              IN [b EXCEPT !.acks=Restrict(@,{k \in DOMAIN @:k>m.opnum})]
OnCommitResult(s,i,m) ==
 LET a == AcceptFromPrimary(s,i,m.view)
 IN IF ~CanAccept(s,i,m.view) THEN a    \* lib.rs:776-784
 ELSE IF m.commit>Len(s.log) THEN StateTransfer(a,i)
 ELSE CommitUpTo(a,i,m.commit,FALSE)
OnGetStateResult(s,i,m) ==             \* lib.rs:824-837, no primary-only guard
 IF s.status/="Normal" \/ m.view/=s.view \/ m.opnum>Len(s.log) THEN s
 ELSE Enqueue(s,<<[Msg("NewState",i,m.src,s.view) EXCEPT
        !.log=SubSeq(s.log,m.opnum+1,Len(s.log)), !.start=m.opnum,
        !.opnum=Len(s.log), !.commit=s.commit]>>)
OnNewStateResult(s,i,m) ==
 IF m.view/=s.view THEN s              \* lib.rs:850-853
 ELSE IF Len(m.log)/=m.opnum-m.start THEN [s EXCEPT !.error="NewState length assertion"]
 ELSE LET a == [s EXCEPT !.heard=TRUE]  \* lib.rs:854 before status dispatch
      IN IF s.status="StateTransfer"
         THEN IF m.start>Len(s.log) \/ m.opnum<=Len(s.log) THEN a
              ELSE LET b == AppendEntries(a,SubSeq(m.log,Len(s.log)-m.start+1,Len(m.log)))
                       c == CommitUpTo(b,i,m.commit,FALSE) \* lib.rs:865-873
                   IN PrepareOK([c EXCEPT !.status="Normal"],i)
         ELSE IF s.status="ViewChange" /\ s.catching
         THEN IF m.start/=s.commit THEN a
              ELSE LET b == InstallLog(a,Prefix(s.log,m.start) \o m.log,"NewState")
                       c == EnterNormal(CommitUpTo(b,i,m.commit,FALSE))
                   IN PrepareOK(c,i)  \* lib.rs:875-893
         ELSE a
OnStartViewChangeResult(s,i,m) ==
 IF m.view<s.view THEN s               \* lib.rs:907-918
 ELSE IF m.view=s.view /\ s.status/="ViewChange"
 THEN IF s.status="Normal" /\ Primary(s.view)=i
      THEN Enqueue(s,<<StartViewMsg(s,i,m.src)>>) ELSE s
 ELSE LET a == IF m.view>s.view THEN StartViewChange(s,i,m.view) ELSE s
      IN MaybeSendDoViewChange([a EXCEPT !.svc=@ \cup {m.src}],i) \* 920-921
OnDoViewChangeResult(s,i,m) ==
 \* lib.rs:609 runs before the handler view/status guards.
 IF Len(m.log)/=m.opnum THEN [s EXCEPT !.error="DoViewChange length assertion"]
 ELSE IF m.view<s.view \/ Primary(m.view)/=i THEN s  \* lib.rs:932-934
 ELSE IF m.view=s.view /\ s.status="Normal"
 THEN Enqueue(s,<<StartViewMsg(s,i,m.src)>>)     \* lib.rs:937-940
 ELSE LET a == IF m.view>s.view THEN StartViewChange(s,i,m.view) ELSE s
      IN RecordDoViewChange(a,i,m)            \* lib.rs:935-936,942
OnStartViewResult(s,i,m) ==
 IF Len(m.log)/=m.opnum THEN [s EXCEPT !.error="StartView length assertion"]
 ELSE IF m.view<s.view \/ (m.view=s.view /\ s.status/="ViewChange") THEN s
 ELSE LET a == InstallLog([s EXCEPT !.view=m.view],m.log,"StartView")
          b == EnterNormal(CommitUpTo(a,i,m.commit,FALSE))
      IN PrepareOK([b EXCEPT !.acks=Empty],i)  \* lib.rs:623,957-967
OnRecoveryResult(s,i,m) ==
 IF m.view>s.view THEN StartViewChange(s,i,m.view) \* lib.rs:1132-1134
 ELSE IF s.status/="Normal" THEN s            \* lib.rs:1136-1149
 ELSE Enqueue(s,<<[Msg("RecoveryResponse",i,m.src,s.view) EXCEPT
            !.nonce=m.nonce, !.hasState=(Primary(s.view)=i),
            !.log=IF Primary(s.view)=i THEN s.log ELSE <<>>,
            !.commit=IF Primary(s.view)=i THEN s.commit ELSE 0]>>)
OnRecoveryResponseResult(s,i,m) ==
 IF s.status/="Recovering" \/ m.nonce/=s.nonce THEN s \* lib.rs:1166-1168
 ELSE LET rs == Put(s.responses,m.src,m)        \* lib.rs:1169-1170 overwrite
          a == [s EXCEPT !.responses=rs]
      IN IF Cardinality(DOMAIN rs)<Quorum THEN a
         ELSE LET latest == Maximum({rs[j].view:j \in DOMAIN rs})
                  p == Primary(latest)
              \* lib.rs:1180-1193: current map max, persisted floor, exact primary.
              IN IF latest<s.view \/ p \notin DOMAIN rs THEN a
                 ELSE IF ~rs[p].hasState \/ rs[p].view/=latest THEN a
                 ELSE LET b == [a EXCEPT !.responses=Empty,!.view=latest]
                          c == InstallLog(b,rs[p].log,"Recovery")
                      IN EnterNormal(CommitUpTo(c,i,rs[p].commit,FALSE))

NoteStable(s) ==                       \* lib.rs:1291-1295: saturating projection
 [s EXCEPT !.stable=Min(@+1,PrimaryTimeout),
           !.attempts=IF s.stable+1>=PrimaryTimeout THEN 0 ELSE @]
TimedOut(s) == s.waiting>=PrimaryTimeout*(2^Min(s.attempts,10)) \* 1302-1305
RECURSIVE ResendPrepares(_,_,_)
ResendPrepares(s,i,k) == IF k>Len(s.log) THEN s
 ELSE ResendPrepares(Broadcast(s,PrepareMsg(s,i,k),i),i,k+1)
OnIdleResult(s,i) ==
 CASE s.status="Normal" /\ Primary(s.view)=i ->
      \* lib.rs:1235-1253: Commit broadcast precedes ordered Prepare broadcasts.
      ResendPrepares(Broadcast(NoteStable(s),
                    [Msg("Commit",i,0,s.view) EXCEPT !.commit=s.commit],i),i,s.commit+1)
 [] s.status="Recovering" -> Broadcast(s,RecoveryMsg(s,i),i) \* 1255
 [] s.status \in {"Normal","StateTransfer"} ->
      LET a == IF s.status="StateTransfer" THEN StateTransfer(s,i) ELSE s
          b == [a EXCEPT !.heard=FALSE]
      IN IF s.heard THEN NoteStable([b EXCEPT !.waiting=0]) \* lib.rs:1257-1262
         ELSE LET c == [b EXCEPT !.stable=0,!.waiting=@+1]
              IN IF TimedOut(c) THEN StartViewChange(c,i,s.view+1) ELSE c \*1263-1267
 [] s.status="ViewChange" ->
      LET a == [s EXCEPT !.waiting=@+1]
      IN IF TimedOut(a) THEN StartViewChange(a,i,s.view+1) \* lib.rs:1270-1272
         ELSE IF a.catching THEN GetState(a,i,a.commit)   \* 1273-1275
         ELSE LET b == Broadcast(a,Msg("StartViewChange",i,0,a.view),i)
              IN IF b.dvcSent THEN SendDoViewChange(b,i) ELSE b \* 1276-1282
 [] OTHER -> s

\* Scenarios 2-4: durable and volatile owner state, historical commitment,
\* original invocations/responses/HB, recovery incarnations. Scenario 1: tx
\* immutable frame provenance and admitted messages. Scenario 5: stable set.
VARIABLES replica, durableView, owner, incarnation, network, client,
          committedHistory, invocations, responses, happensBefore,
          historyViolation, publicationViolation, tx, nextFrame,
          phase, healthySet
replicaVars == <<replica,durableView,owner,incarnation>>
clientVars == <<client,invocations,responses,happensBefore>>
ghostVars == <<committedHistory,historyViolation,publicationViolation>>
transportVars == <<network,tx,nextFrame>>
stabilityVars == <<phase,healthySet>>
vars == <<replicaVars,clientVars,ghostVars,transportVars,stabilityVars>>

\* Only current commitments are compared by position; uncommitted suffixes
\* may differ across views. Installing an old snapshot can legitimately lag.
\* A DVC choice in a later view must include already executed earlier-view ops.
InstallViolates(s) ==
 /\ s.install.kind/="none"
 /\ \E h \in committedHistory :
       \/ /\ h.view<=s.install.view /\ h.pos<=Len(s.install.log)
          /\ s.install.log[h.pos]/=h.entry
       \/ /\ s.install.kind="DVC" /\ h.view<s.install.view
          /\ h.pos>Len(s.install.log)
LocalStep(i,s) ==
 /\ replica'=[replica EXCEPT ![i]=s]
 /\ owner'=[owner EXCEPT ![i]="persist"] \* main.rs:749-750; lib.rs:14-21
 /\ committedHistory'=committedHistory \cup SeqSet(s.executed)
 /\ historyViolation'=historyViolation \/ InstallViolates(s)
 /\ UNCHANGED <<durableView,incarnation,publicationViolation>>

\* Each received message calls precisely one complete implementation handler.
\* keep=TRUE represents a network duplicate, counted only in MC.
Receive(i,m,keep,s) ==
 /\ i \in Server /\ m \in network /\ m.dst=i /\ owner[i]="ready"
 /\ LocalStep(i,s)
 /\ network'=IF keep THEN network ELSE network \ {m}
 /\ UNCHANGED <<clientVars,tx,nextFrame,stabilityVars>>
S(i) == ResetAudit(replica[i])
RecoveringDrop(i,m,keep) ==             \* lib.rs:530-536
 /\ replica[i].status="Recovering" /\ m.kind/="RecoveryResponse"
 /\ Receive(i,m,keep,S(i))
HandlerReady(i) == replica[i].status/="Recovering"
\* lib.rs:646-693; dispatch gate lib.rs:530-536.
OnRequest(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Request" /\ Receive(i,m,keep,OnRequestResult(S(i),i,m))
\* lib.rs:708-710,795-812; dispatch gate lib.rs:530-536.
OnPrepareRejected(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Prepare" /\ ~CanAccept(S(i),i,m.view)
 /\ Receive(i,m,keep,OnPrepareResult(S(i),i,m))
\* lib.rs:712-714,898-900; dispatch gate lib.rs:530-536.
OnPrepareGap(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Prepare" /\ CanAccept(S(i),i,m.view)
 /\ m.opnum>Len(replica[i].log)+1 /\ Receive(i,m,keep,OnPrepareResult(S(i),i,m))
\* lib.rs:716-730; dispatch gate lib.rs:530-536.
OnPrepareAppend(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Prepare" /\ CanAccept(S(i),i,m.view)
 /\ m.opnum=Len(replica[i].log)+1 /\ Receive(i,m,keep,OnPrepareResult(S(i),i,m))
\* lib.rs:720-730; dispatch gate lib.rs:530-536.
OnPrepareDuplicate(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Prepare" /\ CanAccept(S(i),i,m.view)
 /\ m.opnum<=Len(replica[i].log) /\ Receive(i,m,keep,OnPrepareResult(S(i),i,m))
\* lib.rs:737-768; dispatch gate lib.rs:530-536.
OnPrepareOk(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="PrepareOk" /\ Receive(i,m,keep,OnPrepareOkResult(S(i),i,m))
\* lib.rs:776-812; dispatch gate lib.rs:530-536.
OnCommit(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Commit" /\ Receive(i,m,keep,OnCommitResult(S(i),i,m))
\* lib.rs:818-837; dispatch gate lib.rs:530-536.
OnGetState(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="GetState" /\ Receive(i,m,keep,OnGetStateResult(S(i),i,m))
\* lib.rs:842-874,893; dispatch gate lib.rs:530-536.
OnNewStateTransfer(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="NewState" /\ replica[i].status="StateTransfer"
 /\ Receive(i,m,keep,OnNewStateResult(S(i),i,m))
\* lib.rs:875-889,893; dispatch gate lib.rs:530-536.
OnNewStateCatchUp(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="NewState" /\ replica[i].status="ViewChange"
 /\ replica[i].catching /\ Receive(i,m,keep,OnNewStateResult(S(i),i,m))
\* lib.rs:850-855,891; dispatch gate lib.rs:530-536.
OnNewStateIgnored(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="NewState"
 /\ ~(replica[i].status="StateTransfer" \/
       (replica[i].status="ViewChange" /\ replica[i].catching))
 /\ Receive(i,m,keep,OnNewStateResult(S(i),i,m))
\* lib.rs:906-921,971-1037; dispatch gate lib.rs:530-536.
OnStartViewChange(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="StartViewChange"
 /\ Receive(i,m,keep,OnStartViewChangeResult(S(i),i,m))
\* lib.rs:609-615,926-943,1043-1090; dispatch gate lib.rs:530-536.
OnDoViewChange(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="DoViewChange"
 /\ Receive(i,m,keep,OnDoViewChangeResult(S(i),i,m))
\* lib.rs:623-624,948-967; dispatch gate lib.rs:530-536.
OnStartView(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="StartView"
 /\ Receive(i,m,keep,OnStartViewResult(S(i),i,m))
\* lib.rs:1131-1149; dispatch gate lib.rs:530-536.
OnRecovery(i,m,keep) ==
 /\ HandlerReady(i) /\ m.kind="Recovery" /\ Receive(i,m,keep,OnRecoveryResult(S(i),i,m))
\* lib.rs:1159-1205; dispatch gate lib.rs:530-536.
OnRecoveryResponse(i,m,keep) ==
 /\ m.kind="RecoveryResponse" /\ Receive(i,m,keep,OnRecoveryResponseResult(S(i),i,m))
ReplicaMessage(i,m,keep) ==
 \/ RecoveringDrop(i,m,keep) \/ OnRequest(i,m,keep)
 \/ OnPrepareRejected(i,m,keep) \/ OnPrepareGap(i,m,keep)
 \/ OnPrepareAppend(i,m,keep) \/ OnPrepareDuplicate(i,m,keep)
 \/ OnPrepareOk(i,m,keep) \/ OnCommit(i,m,keep) \/ OnGetState(i,m,keep)
 \/ OnNewStateTransfer(i,m,keep) \/ OnNewStateCatchUp(i,m,keep)
 \/ OnNewStateIgnored(i,m,keep) \/ OnStartViewChange(i,m,keep)
 \/ OnDoViewChange(i,m,keep) \/ OnStartView(i,m,keep)
 \/ OnRecovery(i,m,keep) \/ OnRecoveryResponse(i,m,keep)
\* lib.rs:1233-1305; dispatch gate lib.rs:530-536.
OnIdle(i) ==
 /\ owner[i]="ready" /\ LocalStep(i,OnIdleResult(S(i),i))
 /\ UNCHANGED <<clientVars,transportVars,stabilityVars>>

\* Owner obeys durability contract; a crash is allowed before or after this.
PersistView(i) ==                       \* lib.rs:14-21; main.rs:570-584,749
 /\ owner[i]="persist" /\ durableView'=[durableView EXCEPT ![i]=replica[i].view]
 /\ owner'=[owner EXCEPT ![i]=IF replica[i].messages= <<>> /\ replica[i].replies= <<>>
                              THEN "ready" ELSE "publish"]
 /\ UNCHANGED <<replica,incarnation,clientVars,ghostVars,transportVars,stabilityVars>>
PublishOutput(i) ==                     \* lib.rs:1467-1474; main.rs:551-559
 /\ owner[i]="publish" /\ durableView[i]=replica[i].view
 /\ LET msgs == replica[i].messages
        reps == replica[i].replies
        m == IF msgs/= <<>> THEN Head(msgs) ELSE Head(reps)
        a == IF msgs/= <<>> THEN [replica[i] EXCEPT !.messages=Tail(@)]
             ELSE [replica[i] EXCEPT !.replies=Tail(@)]
    IN /\ replica'=[replica EXCEPT ![i]=a]
       /\ owner'=[owner EXCEPT ![i]=IF a.messages= <<>> /\ a.replies= <<>>
                                    THEN "ready" ELSE "publish"]
       \* Scenario 1 only: selected Prepare.Put travels through sender framing.
       /\ IF IntegrationMode /\ m.kind="Prepare" /\ m.entry.op.kind="Put"
          THEN /\ tx'=Put(tx,nextFrame,[sent |-> m,stage |-> "queued",admitted |-> m])
               /\ nextFrame'=nextFrame+1 /\ UNCHANGED network
          ELSE /\ network'=network \cup {m} /\ UNCHANGED <<tx,nextFrame>>
       /\ publicationViolation'=publicationViolation \/ m.view>durableView[i]
 /\ UNCHANGED <<durableView,incarnation,clientVars,committedHistory,historyViolation,stabilityVars>>

Unavailable == {i \in Server:owner[i]="down" \/ replica[i].status="Recovering"}
Crash(i) ==                            \* lib.rs:14-18,505-523; Scenario 4
 /\ phase="faults" /\ owner[i]/="down"
 /\ (i \in Unavailable \/ Cardinality(Unavailable)<FailureBudget)
 /\ replica'=[replica EXCEPT ![i]=[NewReplica EXCEPT !.status="Down"]]
 /\ owner'=[owner EXCEPT ![i]="down"]
 \* Already published traffic survives. Locally queued unsent frames die;
 \* bytes of an interrupted body remain available for a later clean EOF.
 /\ tx'=[f \in DOMAIN tx |-> IF tx[f].sent.src=i
          THEN CASE tx[f].stage="queued" -> [tx[f] EXCEPT !.stage="lost"]
                  [] tx[f].stage="partial" -> [tx[f] EXCEPT !.stage="eof"]
                  [] OTHER -> tx[f] ELSE tx[f]]
 /\ UNCHANGED <<durableView,incarnation,network,nextFrame,clientVars,ghostVars,stabilityVars>>
Recover(i) ==                          \* lib.rs:511-524, fresh per-replica nonce
 /\ owner[i]="down" /\ (phase="faults" \/ i \in healthySet)
 /\ LET a == [NewReplica EXCEPT !.status="Recovering",!.view=durableView[i],
                          !.lastNormal=durableView[i],!.nonce=incarnation[i]+1]
    IN replica'=[replica EXCEPT ![i]=Broadcast(a,RecoveryMsg(a,i),i)]
 /\ incarnation'=[incarnation EXCEPT ![i]=@+1]
 /\ owner'=[owner EXCEPT ![i]="persist"]
 /\ UNCHANGED <<durableView,clientVars,ghostVars,transportVars,stabilityVars>>
LoseMessage(m) ==                      \* caller-supplied lossy transport, lib.rs:6-12
 /\ phase="faults" /\ m \in network /\ network'=network \ {m}
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,tx,nextFrame,stabilityVars>>
DiscardUnavailable(m) ==              \* Scenario 5 unavailable endpoint; no sender stall
 /\ m \in network /\ m.dst \in Server
 /\ owner[m.dst]="down" /\ network'=network \ {m}
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,tx,nextFrame,stabilityVars>>

\* Integration refinement is ONLY the demonstrated valid Prepare.PUT final
\* ASCII token prefix. main.rs:79-117,383-409,247-254. Source bytes/hashes are
\* supplied by evidence/frame-regression; abstract AA->A is not literal size.
RunSenderBeginPartial(f) ==
 /\ IntegrationMode /\ f \in DOMAIN tx /\ tx[f].stage="queued"
 /\ owner[tx[f].sent.src]/="down" /\ tx[f].sent.entry.op.value=FullValue
 /\ tx'=[tx EXCEPT ![f].stage="partial"]
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,network,nextFrame,stabilityVars>>
RunSenderComplete(f) ==                \* fragmentation completed with newline is unchanged
 /\ f \in DOMAIN tx /\ tx[f].stage \in {"queued","partial"}
 /\ owner[tx[f].sent.src]/="down"
 /\ network'=network \cup {tx[f].sent} /\ tx'=[tx EXCEPT ![f].stage="complete"]
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,nextFrame,stabilityVars>>
RunPeerAcceptorEOF(f) ==               \* requires interrupted sender, NOT arbitrary loss
 /\ f \in DOMAIN tx /\ tx[f].stage="eof"
 /\ LET m == [tx[f].sent EXCEPT !.entry.op.value=PrefixValue]
    IN /\ network'=network \cup {m}
       /\ tx'=[tx EXCEPT ![f].stage="admitted",![f].admitted=m]
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,nextFrame,stabilityVars>>
RunPeerAcceptorReadError(f) ==          \* main.rs:401 map_while ends without dispatch
 /\ f \in DOMAIN tx /\ tx[f].stage \in {"partial","eof"}
 /\ tx'=[tx EXCEPT ![f].stage="lost"]
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,network,nextFrame,stabilityVars>>

\* Clients have one outstanding call; fresh identities persist across server
\* crashes. This isolates core correctness from the excluded ID-reuse issue.
ClientOnRequest(c,op) ==               \* lib.rs:311-326; main.rs:729-734
 /\ c \in Clients /\ op \in Ops /\ ~client[c].pending
 /\ LET e == [client |-> c,request |-> client[c].next,op |-> op]
        id == RequestId(e)
        m == [Msg("Request",c,Primary(client[c].view),0) EXCEPT !.entry=e]
    IN /\ client'=[client EXCEPT ![c].pending=TRUE,![c].entry=e,![c].next=@+1]
       /\ invocations'=Put(invocations,id,e)
       /\ happensBefore'=happensBefore \cup {<<done,id>>:done \in DOMAIN responses}
       /\ network'=network \cup {m}
 /\ UNCHANGED <<replicaVars,responses,ghostVars,tx,nextFrame,stabilityVars>>
ClientOnIdle(c) ==                    \* lib.rs:353-370, broadcast original pending argument
 /\ client[c].pending
 /\ network'=network \cup {[Msg("Request",c,i,0) EXCEPT !.entry=client[c].entry]:i \in Server}
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,tx,nextFrame,stabilityVars>>
ClientOnReply(m,keep) ==              \* lib.rs:334-347; main.rs:528-539
 /\ m \in network /\ m.kind="Reply" /\ m.dst \in Clients
 /\ LET c == m.dst
        answers == client[c].pending /\ client[c].entry.request=m.entry.request
    IN /\ client'=[client EXCEPT ![c].view=Max(@,m.view),
                                 ![c].pending=IF answers THEN FALSE ELSE @]
       /\ responses'=IF answers THEN Put(responses,RequestId(client[c].entry),m.result)
                      ELSE responses
 /\ network'=IF keep THEN network ELSE network \ {m}
 /\ UNCHANGED <<replicaVars,invocations,happensBefore,ghostVars,tx,nextFrame,stabilityVars>>
Stabilize(h) ==                       \* Scenario 5 environment, not a library transition
 /\ phase="faults" /\ h \subseteq Server /\ Cardinality(h)>=Quorum
 /\ \A i \in Server\h:owner[i]="down"
 /\ healthySet'=h /\ phase'="stable"
 /\ UNCHANGED <<replicaVars,clientVars,ghostVars,transportVars>>

Init ==                               \* lib.rs:292-300,478-501
 /\ replica=[i \in Server |-> NewReplica] /\ durableView=[i \in Server |-> 0]
 /\ owner=[i \in Server |-> "ready"] /\ incarnation=[i \in Server |-> 0]
 /\ network={} /\ client=[c \in Clients |->
         [view |-> 0,next |-> 0,pending |-> FALSE,entry |-> NoEntry]]
 /\ invocations=Empty /\ responses=Empty /\ happensBefore={}
 /\ committedHistory={} /\ historyViolation=FALSE /\ publicationViolation=FALSE
 /\ tx=Empty /\ nextFrame=0 /\ phase="faults" /\ healthySet=Server
Next ==
 \/ \E i \in Server : OnIdle(i) \/ PersistView(i) \/ PublishOutput(i) \/ Crash(i) \/ Recover(i)
 \/ \E i \in Server,m \in network,keep \in BOOLEAN:ReplicaMessage(i,m,keep)
 \/ \E m \in network: LoseMessage(m) \/ DiscardUnavailable(m) \/
                              (\E keep \in BOOLEAN:ClientOnReply(m,keep))
 \/ \E c \in Clients:ClientOnIdle(c) \/ (\E op \in Ops:ClientOnRequest(c,op))
 \/ \E f \in DOMAIN tx:RunSenderBeginPartial(f) \/ RunSenderComplete(f) \/
                           RunPeerAcceptorEOF(f) \/ RunPeerAcceptorReadError(f)
 \/ \E h \in SUBSET Server:Stabilize(h)
Spec == Init /\ [][Next]_vars

\* Standard / structural invariants, lib.rs:34-40,427-475,1325,1349-1377.
TypeOK ==
 /\ DOMAIN replica=Server /\ DOMAIN owner=Server /\ DOMAIN durableView=Server
 /\ DOMAIN incarnation=Server /\ DOMAIN client=Clients
 /\ \A i \in Server:
       /\ replica[i].status \in {"Normal","ViewChange","StateTransfer","Recovering","Down"}
       /\ owner[i] \in {"ready","persist","publish","down"}
       /\ replica[i].view \in Nat /\ durableView[i] \in Nat
       /\ replica[i].commit \in 0..Len(replica[i].log)
       /\ Len(replica[i].executed)=replica[i].commit
       /\ replica[i].svc \subseteq Server /\ DOMAIN replica[i].dvc \subseteq Server
       /\ DOMAIN replica[i].responses \subseteq Server
       /\ replica[i].attempts \in 0..10 /\ replica[i].stable \in 0..PrimaryTimeout
 /\ DOMAIN responses \subseteq DOMAIN invocations /\ healthySet \subseteq Server
 /\ phase \in {"faults","stable"} /\ Cardinality(Unavailable)<=FailureBudget
NoAssertionFailure == \A i \in Server:replica[i].error=""
DistinctQuorumAndPrimary ==
 /\ \A i \in Server:
       /\ \A k \in DOMAIN replica[i].acks:replica[i].acks[k] \subseteq Server
       /\ \A j \in DOMAIN replica[i].dvc:
                       Primary(replica[i].dvc[j].view)=i /\ replica[i].dvc[j].src=j
 /\ \A m \in network:
       m.kind \in {"Prepare","Commit","StartView"} => m.src=Primary(m.view)
CommittedPrefixAgreement ==
 /\ \A a,b \in committedHistory:a.pos=b.pos => a.entry=b.entry
 /\ \A h \in committedHistory:
       RequestId(h.entry) \in DOMAIN invocations /\ invocations[RequestId(h.entry)]=h.entry
 /\ \A i \in Server: \A k \in 1..replica[i].commit:
                          replica[i].log[k]=replica[i].executed[k].entry
CommittedHistorySurvives == ~historyViolation
PreparedPrefixAgreement ==
 \A i,j \in Server:
   (replica[i].status="Normal" /\ replica[j].status="Normal" /\
    replica[i].view=replica[j].view) =>
      \A k \in 1..Min(Len(replica[i].log),Len(replica[j].log)):
                                      replica[i].log[k]=replica[j].log[k]
NoDuplicateExecution ==
 \A i \in Server: \A k,l \in 1..Len(replica[i].log):
     RequestId(replica[i].log[k])=RequestId(replica[i].log[l]) => k=l
DurableViewFloor ==
 /\ ~publicationViolation
 /\ \A i \in Server:owner[i]/="down" => replica[i].view>=durableView[i]

\* Exact finite-history linearizability, including optional completion of
\* pending calls. Arguments come from invocations, NEVER from received logs.
\* Scenarios 1-4; lib.rs:311-347,1362-1377; main.rs:56-62,526-539.
RECURSIVE Evaluate(_)
Evaluate(ids) == IF ids= <<>> THEN [app |-> Nil,results |-> Empty]
 ELSE LET prev == Evaluate(Prefix(ids,Len(ids)-1))
          id == ids[Len(ids)]
          op == invocations[id].op
      IN [app |-> ApplyValue(prev.app,op),
          results |-> Put(prev.results,id,ApplyResult(prev.app,op))]
ClientLinearizability ==
 \E n \in Cardinality(DOMAIN responses)..Cardinality(DOMAIN invocations):
  \E ids \in [1..n -> DOMAIN invocations]:
   /\ Cardinality(SeqSet(ids))=n /\ DOMAIN responses \subseteq SeqSet(ids)
   /\ \A hb \in happensBefore:
        (hb[1] \in SeqSet(ids) /\ hb[2] \in SeqSet(ids)) =>
          (CHOOSE k \in 1..n:ids[k]=hb[1]) < (CHOOSE k \in 1..n:ids[k]=hb[2])
   /\ LET result == Evaluate(ids).results
      IN \A id \in DOMAIN responses:result[id]=responses[id]

\* Finite-state hunts supply fair, bounded timing in MC.tla. These properties
\* alone do not assume eventual delivery is a synchronous timing guarantee.
RecoveryCompletesUnderStability ==
 \A i \in Server: (phase="stable" /\ i \in healthySet /\
                    replica[i].status="Recovering") ~> (replica[i].status="Normal")
StableMajorityServesNewWork ==
 \A c \in Clients: (phase="stable" /\ client[c].pending) ~> (~client[c].pending)
=============================================================================
