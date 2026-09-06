------------------------------ MODULE base ------------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC

\* Category A; source revision 3ac0104a567092139534c9022205d02281a2da41.
\* Brief 3.1 baseline only. No Scenario-specific caller deviations are injected.
\* One atomic owner call followed by conforming persistence/output publication.
\* lib.rs:6-21: no concurrent observer can interleave inside a library handler.
\* The concrete test application is an integer accumulator (StateMachine:53-60).
\* applied/history are observers, never protocol guards. Integer overflow, OS
\* scheduling, identity allocation policy, and nonconforming callers are excluded.

CONSTANTS N, Clients, Operations, PrimaryTimeout
Servers == 0..(N - 1)
Primary(v) == v % N                          \* lib.rs:86-98
Quorum == (N \div 2) + 1
ASSUME /\ N >= 2 /\ PrimaryTimeout >= 1
       /\ Clients /= {} /\ "" \notin Clients /\ Operations \subseteq Int /\ Operations /= {}

VARIABLES replicas, durableView, live, incarnations, usedNonces,
          clients, network, committedHistory, replyHistory, lastOutput
vars == <<replicas, durableView, live, incarnations, usedNonces,
          clients, network, committedHistory, replyHistory, lastOutput>>

Min(a,b) == IF a < b THEN a ELSE b
Max(a,b) == IF a > b THEN a ELSE b
Maximum(S) == CHOOSE x \in S : \A y \in S : x >= y
Prefix(s,n) == SubSeq(s,1,n)
Elements(s) == {s[k] : k \in 1..Len(s)}
EmptyMap == [x \in {} |-> x]
Put(f,k,v) == [x \in DOMAIN f \cup {k} |-> IF x = k THEN v ELSE f[x]]
Remove(f,S) == [x \in DOMAIN f \ S |-> f[x]]
RECURSIVE Sum(_)
Sum(s) == IF s = <<>> THEN 0 ELSE Head(s).op + Sum(Tail(s))
RECURSIVE Flatten(_)
Flatten(ss) == IF ss = <<>> THEN <<>> ELSE Head(ss) \o Flatten(Tail(ss))
\* lib.rs:133-270: full message payload. Unused fields are canonical defaults.
\* from/to are authentic transport metadata, NOT additional handler guards.
Message(t,from,to) ==
    [kind |-> t, src |-> from, dst |-> to, view |-> 0, opnum |-> 0,
     commit |-> 0, start |-> 0, lastNormal |-> 0, nonce |-> 0,
     hasState |-> FALSE, log |-> <<>>,
     request |-> [client |-> "", number |-> 0, op |-> 0],
     result |-> 0]
ToOthers(i,m) ==
    [k \in 1..(N-1) |-> [m EXCEPT !.dst = IF k <= i THEN k-1 ELSE k]]
\* lib.rs:1404-1413: output order is membership order, skipping self.
Emit(s,ms) == [s EXCEPT !.out = @ \o ms]

\* lib.rs:478-503: Replica::new; application state is empty/zero.
NewReplica ==
    [status |-> "Normal", view |-> 0, lastNormal |-> 0,
     commit |-> 0, log |-> <<>>, acks |-> EmptyMap, table |-> EmptyMap,
     heard |-> TRUE, waiting |-> 0, attempts |-> 0, stable |-> 0,
     svc |-> {}, dvcSent |-> FALSE, dvc |-> EmptyMap, catching |-> FALSE,
     nonce |-> 0, responses |-> EmptyMap, app |-> 0, applied |-> <<>>,
     out |-> <<>>]
\* lib.rs:292-300: Client::new. None is represented by an empty sequence.
NewClient == [view |-> 0, next |-> 0, pending |-> <<>>]

\* lib.rs:1310-1319: table overwrite occurs even for an older request number.
AppendToLog(s,e) ==
    [s EXCEPT !.log = Append(@,e),
              !.table = Put(@,e.client,[number |-> e.number,
                                         hasReply |-> FALSE, result |-> 0])]
RECURSIVE AppendEntries(_,_)
AppendEntries(s,es) ==
    IF es = <<>> THEN s ELSE AppendEntries(AppendToLog(s,Head(es)),Tail(es))

\* lib.rs:1324-1344: rebuild in log order, preserving only matching committed
\* table replies. Do NOT assume the new log's committed prefix is equal.
InstallLogState(s,lg) ==
    LET cs == {lg[k].client : k \in 1..Len(lg)}
        tbl == [c \in cs |->
            LET k == Maximum({j \in 1..Len(lg) : lg[j].client = c})
                e == lg[k]
                keep == IF c \in DOMAIN s.table
                        THEN k <= s.commit /\ s.table[c].number = e.number
                             /\ s.table[c].hasReply
                        ELSE FALSE
            IN [number |-> e.number, hasReply |-> keep,
                result |-> IF keep THEN s.table[c].result ELSE 0]]
    IN IF Assert(Len(lg) >= s.commit, "install_log:1325 length assertion")
       THEN [s EXCEPT !.log = lg, !.table = tbl] ELSE s

\* lib.rs:1362-1376: apply exactly once for each newly committed index;
\* no deduplication guard is invented at execution time.
CommitOp(s,i,sendReply) ==
    LET e == s.log[s.commit+1]
        result == s.app + e.op
        tbl == IF e.client \in DOMAIN s.table
               THEN IF s.table[e.client].number = e.number
                    THEN [s.table EXCEPT ![e.client].hasReply = TRUE,
                                         ![e.client].result = result]
                    ELSE s.table
               ELSE s.table
        m == [Message("Reply",i,e.client) EXCEPT
                 !.view = s.view, !.request = e, !.result = result]
    IN [s EXCEPT !.commit = @+1, !.app = result,
                 !.applied = Append(@,e), !.table = tbl,
                 !.out = IF sendReply THEN Append(@,m) ELSE @]
\* lib.rs:1349-1355: monotone while loop; never clamp except at on_prepare.
RECURSIVE CommitUpTo(_,_,_,_)
CommitUpTo(s,n,i,reply) ==
    IF s.commit >= n THEN s
    ELSE IF Assert(s.commit < Len(s.log), "commit_op:1363 missing log index")
         THEN CommitUpTo(CommitOp(s,i,reply),n,i,reply) ELSE s

\* lib.rs:994-998,1114-1121: attempts, acks, recovery nonce are NOT reset.
ClearViewChangeState(s) ==
    [s EXCEPT !.svc = {}, !.dvcSent = FALSE, !.dvc = EmptyMap]
EnterNormal(s) ==
    ClearViewChangeState([s EXCEPT !.status = "Normal", !.lastNormal = s.view,
        !.catching = FALSE, !.heard = TRUE, !.waiting = 0, !.stable = 0])

\* lib.rs:1083-1090,1381-1396: helpers use the current local view and log.
StartViewMessage(s,i,to) ==
    [Message("StartView",i,to) EXCEPT !.view = s.view, !.log = s.log,
                                          !.opnum = Len(s.log), !.commit = s.commit]
SendStartView(s,i,to) == Emit(s,<<StartViewMessage(s,i,to)>>)
SendPrepareOk(s,i) == Emit(s,<<[Message("PrepareOk",i,Primary(s.view)) EXCEPT
                                           !.view = s.view, !.opnum = Len(s.log)]>>)
SendGetState(s,i,n) == Emit(s,<<[Message("GetState",i,Primary(s.view)) EXCEPT
                                                !.view = s.view, !.opnum = n]>>)
\* lib.rs:898-900: a same-view transfer does not clear view-change state.
StateTransfer(s,i) == SendGetState([s EXCEPT !.status = "StateTransfer"],i,Len(s.log))

\* lib.rs:1043-1059: BTreeMap insert overwrites a prior sender report; choose
\* max(last_normal_view, length), with last equal key in ascending replica ID.
RecordDoViewChange(s,i,from,d) ==
    LET reports == Put(s.dvc,from,d)
        s1 == [s EXCEPT !.dvc = reports]
        ids == DOMAIN reports
        best == CHOOSE b \in ids : \A j \in ids :
            \/ reports[b].lastNormal > reports[j].lastNormal
            \/ /\ reports[b].lastNormal = reports[j].lastNormal
               /\ \/ Len(reports[b].log) > Len(reports[j].log)
                  \/ /\ Len(reports[b].log) = Len(reports[j].log)
                     /\ b >= j
        k == Maximum({reports[j].commit : j \in ids})
    IN IF Cardinality(ids) < Quorum THEN s1
       ELSE
         \* lib.rs:1066-1075: install, commit/reply, enter Normal, self-ack suffix.
         LET s2 == EnterNormal(CommitUpTo(InstallLogState(s1,reports[best].log),k,i,TRUE))
             s3 == [s2 EXCEPT !.acks = [p \in (s2.commit+1)..Len(s2.log) |-> {i}]]
         \* lib.rs:1076-1080: broadcast chosen view after committing locally.
         IN Emit(s3,ToOthers(i,StartViewMessage(s3,i,i)))

\* lib.rs:1015-1037: primary records its own DVC synchronously, not via network.
SendDoViewChange(s,i) ==
    LET d == [lastNormal |-> s.lastNormal, log |-> s.log, commit |-> s.commit]
    IN IF Primary(s.view) = i THEN RecordDoViewChange(s,i,i,d)
       ELSE Emit(s,<<[Message("DoViewChange",i,Primary(s.view)) EXCEPT
             !.view = s.view, !.lastNormal = d.lastNormal, !.log = d.log,
             !.opnum = Len(d.log), !.commit = d.commit]>>)
\* lib.rs:1001-1010: f OTHER SVC senders; catching_up blocks initial DVC.
MaybeSendDoViewChange(s,i) ==
    IF s.status /= "ViewChange" \/ s.catching \/ s.dvcSent
       \/ Cardinality(s.svc) < N \div 2 THEN s
    ELSE SendDoViewChange([s EXCEPT !.dvcSent = TRUE],i)
\* lib.rs:979-991: attempts increment only when entering from ViewChange.
StartViewChange(s,i,v) ==
    LET s1 == ClearViewChangeState([s EXCEPT !.view = v, !.status = "ViewChange",
         !.catching = FALSE, !.waiting = 0,
         !.attempts = IF s.status = "ViewChange" THEN @+1 ELSE @])
        ms == ToOthers(i,[Message("StartViewChange",i,i) EXCEPT !.view = v])
    IN MaybeSendDoViewChange(Emit(s1,ms),i)
\* lib.rs:1095-1108: same-view catching-up is idempotent; no attempts increment.
CatchUpWithView(s,i,v) ==
    IF s.view = v /\ s.catching THEN s
    ELSE SendGetState(ClearViewChangeState([s EXCEPT !.view = v,
        !.status = "ViewChange", !.catching = TRUE, !.waiting = 0]),i,s.commit)

\* lib.rs:795-812: side effects of a rejected Prepare/Commit are significant.
AcceptFromPrimaryState(s,i,v) ==
    IF v < s.view THEN s
    ELSE IF v > s.view THEN CatchUpWithView(s,i,v)
    ELSE LET s1 == [s EXCEPT !.heard = TRUE]
         IN IF s.status = "ViewChange" THEN CatchUpWithView(s1,i,v) ELSE s1
AcceptFromPrimary(s,i,v) ==
    v = s.view /\ s.status = "Normal" /\ Primary(s.view) /= i

\* lib.rs:646-694: ignore backup/non-normal, older, pending duplicate;
\* executed latest duplicate gets cached reply; only a new request is appended.
OnRequestState(s,i,m) ==
    IF Primary(s.view) /= i \/ s.status /= "Normal" THEN s
    ELSE LET e == m.request
             old == IF e.client \in DOMAIN s.table
                    THEN s.table[e.client].number ELSE -1
         IN IF e.number < old THEN s
            ELSE IF e.number = old
            THEN IF s.table[e.client].hasReply
                 THEN Emit(s,<<[Message("Reply",i,e.client) EXCEPT
                      !.view = s.view, !.request = e,
                      !.result = s.table[e.client].result]>>)
                 ELSE s
            ELSE LET s1 == AppendToLog(s,e)
                     s2 == [s1 EXCEPT !.acks = Put(@,Len(s1.log),{i})]
                 IN Emit(s2,ToOthers(i,[Message("Prepare",i,i) EXCEPT
                    !.view = s.view, !.opnum = Len(s1.log),
                    !.request = e, !.commit = s.commit]))

\* lib.rs:708-730: gap returns before commit/ack; duplicate is not compared to
\* stored content; reply acknowledges local op_number, not message op_number.
OnPrepareGap(s,i,m) == StateTransfer(s,i)
OnPrepareAppend(s,i,m) ==
    LET s1 == AppendToLog(s,m.request)
    IN SendPrepareOk(CommitUpTo(s1,Min(m.commit,Len(s1.log)),i,FALSE),i)
OnPrepareDuplicate(s,i,m) ==
    SendPrepareOk(CommitUpTo(s,Min(m.commit,Len(s.log)),i,FALSE),i)
OnPrepareState(s,i,m) ==
    LET s1 == AcceptFromPrimaryState(s,i,m.view)
    IN IF ~AcceptFromPrimary(s,i,m.view) THEN s1
       ELSE IF m.opnum > Len(s1.log)+1 THEN OnPrepareGap(s1,i,m)
       ELSE IF m.opnum = Len(s1.log)+1 THEN OnPrepareAppend(s1,i,m)
       ELSE OnPrepareDuplicate(s1,i,m)

\* lib.rs:743-758: only an existing ack slot, distinct newly inserted sender,
\* and size EXACTLY quorum triggers commit. No inferred self-quorum fast path.
OnPrepareOkState(s,i,m) ==
    IF m.view /= s.view \/ Primary(s.view) /= i \/ s.status /= "Normal"
       \/ m.opnum <= s.commit THEN s
    ELSE IF m.opnum \notin DOMAIN s.acks THEN s
    ELSE LET old == s.acks[m.opnum]
             s1 == [s EXCEPT !.acks[m.opnum] = @ \cup {m.src}]
         IN IF m.src \in old \/ Cardinality(old \cup {m.src}) /= Quorum THEN s1
            \* lib.rs:765-767: execute/reply prefix, then remove all prior slots.
            ELSE LET s2 == CommitUpTo(s1,m.opnum,i,TRUE)
                 IN [s2 EXCEPT !.acks = Remove(@,1..m.opnum)]

\* lib.rs:776-784: Commit gap causes transfer without executing a partial prefix.
OnCommitState(s,i,m) ==
    LET s1 == AcceptFromPrimaryState(s,i,m.view)
    IN IF ~AcceptFromPrimary(s,i,m.view) THEN s1
       ELSE IF m.commit > Len(s1.log) THEN StateTransfer(s1,i)
       ELSE CommitUpTo(s1,m.commit,i,FALSE)
\* lib.rs:824-837: notably NO is_primary check is added to GetState.
OnGetStateState(s,i,m) ==
    IF s.status /= "Normal" \/ m.view /= s.view \/ m.opnum > Len(s.log) THEN s
    ELSE Emit(s,<<[Message("NewState",i,m.src) EXCEPT !.view = m.view,
         !.log = SubSeq(s.log,m.opnum+1,Len(s.log)), !.start = m.opnum,
         !.opnum = Len(s.log), !.commit = s.commit]>>)

\* lib.rs:856-873: same-view suffix accepts overlap; status-only Normal update.
OnNewStateTransfer(s,i,m) ==
    IF m.start > Len(s.log) \/ m.opnum <= Len(s.log) THEN s
    ELSE LET s1 == AppendEntries(s,SubSeq(m.log,Len(s.log)-m.start+1,Len(m.log)))
             s2 == CommitUpTo(s1,m.commit,i,FALSE)
         IN SendPrepareOk([s2 EXCEPT !.status = "Normal"],i)
\* lib.rs:875-889: cross-view replacement is anchored EXACTLY at current commit.
OnNewStateCatchUp(s,i,m) ==
    IF m.start /= s.commit THEN s
    ELSE LET lg == Prefix(s.log,m.start) \o m.log
             s1 == InstallLogState(s,lg)
         IN SendPrepareOk(EnterNormal(CommitUpTo(s1,m.commit,i,FALSE)),i)
\* lib.rs:850-854,891-893: matched view sets heard even when later ignored.
OnNewStateState(s,i,m) ==
    IF m.view /= s.view THEN s
    ELSE IF Assert(m.opnum >= m.start /\ Len(m.log) = m.opnum-m.start,
                   "on_new_state:853 malformed suffix")
         THEN LET s1 == [s EXCEPT !.heard = TRUE]
              IN CASE s.status = "StateTransfer" -> OnNewStateTransfer(s1,i,m)
                   [] s.status = "ViewChange" /\ s.catching -> OnNewStateCatchUp(s1,i,m)
                   [] OTHER -> s1
         ELSE s

\* lib.rs:906-921: late same-view SVC gets StartView only at a Normal primary.
OnStartViewChangeState(s,i,m) ==
    IF m.view < s.view THEN s
    ELSE IF m.view = s.view /\ s.status /= "ViewChange"
         THEN IF s.status = "Normal" /\ Primary(s.view) = i
              THEN SendStartView(s,i,m.src) ELSE s
         ELSE LET s1 == IF m.view > s.view THEN StartViewChange(s,i,m.view) ELSE s
              IN MaybeSendDoViewChange([s1 EXCEPT !.svc = @ \cup {m.src}],i)
\* lib.rs:932-942: candidate primary guard precedes newer-view adoption.
OnDoViewChangeState(s,i,m) ==
    IF m.view < s.view \/ Primary(m.view) /= i THEN s
    ELSE IF m.view = s.view /\ s.status = "Normal" THEN SendStartView(s,i,m.src)
    ELSE LET s1 == IF m.view > s.view THEN StartViewChange(s,i,m.view) ELSE s
         IN RecordDoViewChange(s1,i,m.src,
                  [lastNormal |-> m.lastNormal, log |-> m.log, commit |-> m.commit])
\* lib.rs:957-967: same-view StartView allowed ONLY in ViewChange.
OnStartViewState(s,i,m) ==
    IF m.view < s.view \/ (m.view = s.view /\ s.status /= "ViewChange") THEN s
    ELSE LET s1 == InstallLogState([s EXCEPT !.view = m.view],m.log)
             s2 == EnterNormal(CommitUpTo(s1,m.commit,i,FALSE))
         IN SendPrepareOk([s2 EXCEPT !.acks = EmptyMap],i)

\* lib.rs:1131-1149: later persisted view induces view change and NO response.
OnRecoveryState(s,i,m) ==
    IF m.view > s.view /\ s.status /= "Recovering" THEN StartViewChange(s,i,m.view)
    ELSE IF s.status /= "Normal" THEN s
    ELSE Emit(s,<<[Message("RecoveryResponse",i,m.src) EXCEPT
           !.view = s.view, !.nonce = m.nonce, !.hasState = (Primary(s.view) = i),
           !.log = IF Primary(s.view) = i THEN s.log ELSE <<>>,
           !.commit = IF Primary(s.view) = i THEN s.commit ELSE 0]>>)
\* lib.rs:1166-1193: nonce/status guard; overwrite sender, max view, then matching
\* primary payload. Prior sender reports are not monotone-filtered by view.
OnRecoveryResponseState(s,i,m) ==
    IF s.status /= "Recovering" \/ m.nonce /= s.nonce THEN s
    ELSE LET rs == Put(s.responses,m.src,[view |-> m.view, hasState |-> m.hasState,
                                                   log |-> m.log, commit |-> m.commit])
             s1 == [s EXCEPT !.responses = rs]
             v == Maximum({rs[j].view : j \in DOMAIN rs})
             p == Primary(v)
         IN IF Cardinality(DOMAIN rs) < Quorum \/ v < s.view THEN s1
            ELSE IF p \notin DOMAIN rs THEN s1
            ELSE IF ~rs[p].hasState \/ rs[p].view /= v THEN s1
            ELSE
              \* lib.rs:1201-1205: no PrepareOk on recovery completion.
              LET s2 == [s1 EXCEPT !.responses = EmptyMap, !.view = v]
              IN EnterNormal(CommitUpTo(InstallLogState(s2,rs[p].log),rs[p].commit,i,FALSE))

\* lib.rs:1208-1214: authentic request carries persisted/current view and nonce.
SendRecovery(s,i) == Emit(s,ToOthers(i,[Message("Recovery",i,i) EXCEPT
                                              !.view = s.view, !.nonce = s.nonce]))
\* lib.rs:1291-1305: exact timer counters, backoff shift capped at 10.
NoteStable(s) == [s EXCEPT !.stable = @+1,
    !.attempts = IF s.stable+1 >= PrimaryTimeout THEN 0 ELSE @]
WaitTimedOut(s) == s.waiting >= PrimaryTimeout * (2 ^ Min(s.attempts,10))
\* lib.rs:1235-1253: heartbeat precedes each uncommitted Prepare, in op order.
OnIdlePrimary(s,i) ==
    LET heartbeat == ToOthers(i,[Message("Commit",i,i) EXCEPT
                                                !.view = s.view, !.commit = s.commit])
        prepares == [k \in 1..(Len(s.log)-s.commit) |->
            ToOthers(i,[Message("Prepare",i,i) EXCEPT !.view = s.view,
                !.commit = s.commit, !.opnum = s.commit+k, !.request = s.log[s.commit+k]])]
    IN Emit(NoteStable(s),heartbeat \o Flatten(prepares))
\* lib.rs:1256-1268: transfer resend occurs BEFORE timeout; heard swap happens
\* even in StateTransfer; note_stable is called there too, matching Rust.
OnIdleBackup(s,i) ==
    LET s1 == IF s.status = "StateTransfer" THEN StateTransfer(s,i) ELSE s
        s2 == [s1 EXCEPT !.heard = FALSE]
    IN IF s.heard THEN NoteStable([s2 EXCEPT !.waiting = 0])
       ELSE LET s3 == [s2 EXCEPT !.stable = 0, !.waiting = @+1]
            IN IF WaitTimedOut(s3) THEN StartViewChange(s3,i,s.view+1) ELSE s3
\* lib.rs:1270-1283: catching-up retries GetState; election retries SVC and,
\* if sent, DVC (including synchronous local recording at the primary).
OnIdleViewChange(s,i) ==
    LET s1 == [s EXCEPT !.waiting = @+1]
    IN IF WaitTimedOut(s1) THEN StartViewChange(s1,i,s.view+1)
       ELSE IF s.catching THEN SendGetState(s1,i,s.commit)
       ELSE LET s2 == Emit(s1,ToOthers(i,[Message("StartViewChange",i,i) EXCEPT !.view = s.view]))
            IN IF s.dvcSent THEN SendDoViewChange(s2,i) ELSE s2
OnIdleState(s,i) ==
    CASE s.status = "Normal" /\ Primary(s.view) = i -> OnIdlePrimary(s,i)
      [] s.status = "Recovering" -> SendRecovery(s,i)       \* lib.rs:1255
      [] s.status = "ViewChange" -> OnIdleViewChange(s,i)
      [] OTHER -> OnIdleBackup(s,i)

\* lib.rs:530-639: recovery firewall is checked before variant assertions.
Handle(s,i,m) ==
    IF s.status = "Recovering" /\ m.kind /= "RecoveryResponse" THEN s
    ELSE IF Assert(m.kind \notin {"DoViewChange","StartView"} \/ Len(m.log)=m.opnum,
                   "on_message:609,623 malformed full log")
    THEN CASE m.kind = "Request" -> OnRequestState(s,i,m)
      [] m.kind = "Prepare" -> OnPrepareState(s,i,m)
      [] m.kind = "PrepareOk" -> OnPrepareOkState(s,i,m)
      [] m.kind = "Commit" -> OnCommitState(s,i,m)
      [] m.kind = "GetState" -> OnGetStateState(s,i,m)
      [] m.kind = "NewState" -> OnNewStateState(s,i,m)
      [] m.kind = "StartViewChange" -> OnStartViewChangeState(s,i,m)
      [] m.kind = "DoViewChange" -> OnDoViewChangeState(s,i,m)
      [] m.kind = "StartView" -> OnStartViewState(s,i,m)
      [] m.kind = "Recovery" -> OnRecoveryState(s,i,m)
      [] m.kind = "RecoveryResponse" -> OnRecoveryResponseState(s,i,m)
    ELSE s

\* A finite multiset represented as a message->positive count function.
\* lib.rs:10-12: owner-selected delivery, loss, and duplication; no forged sends.
BagAdd(b,ms) ==
    [m \in DOMAIN b \cup Elements(ms) |->
        (IF m \in DOMAIN b THEN b[m] ELSE 0)
        + Cardinality({k \in 1..Len(ms) : ms[k]=m})]
BagTake(b,m) == IF b[m]=1 THEN Remove(b,{m}) ELSE [b EXCEPT ![m]=@-1]
\* Observer preserves every committed index/content/result across crash and time.
CommitObservations(s) ==
    {[index |-> k, request |-> s.applied[k], result |-> Sum(Prefix(s.applied,k))]
        : k \in 1..Len(s.applied)}
Replies(ms) == {m \in Elements(ms) : m.kind="Reply"}
\* lib.rs:473-474,1467-1474: independent queues; canonical trace order is
\* protocol outbox first, then replies, retaining order within each queue.
CanonicalOutput(ms) == SelectSeq(ms,LAMBDA m : m.kind /= "Reply")
                       \o SelectSeq(ms,LAMBDA m : m.kind = "Reply")
\* lib.rs:14-21,1467-1474: atomic conforming persist-before-release wrapper.
\* r.out is transient in pure helpers; every stable state has empty outboxes.
PublishReplica(i,s,remaining) ==
    /\ replicas' = [replicas EXCEPT ![i] = [s EXCEPT !.out = <<>>]]
    /\ durableView' = [durableView EXCEPT ![i] = s.view]
    /\ network' = BagAdd(remaining,s.out)
    /\ committedHistory' = committedHistory \cup CommitObservations(s)
    /\ replyHistory' = replyHistory \cup Replies(s.out)
    /\ lastOutput' = CanonicalOutput(s.out)
    /\ UNCHANGED <<live,incarnations,usedNonces,clients>>

\* lib.rs:528-639: separate handler actions, all include the recovery firewall.
DeliverKind(i,m,kind) ==
    /\ i \in live /\ m \in DOMAIN network /\ m.dst=i /\ m.kind=kind
    /\ PublishReplica(i,Handle(replicas[i],i,m),BagTake(network,m))
OnRequest(i,m) == DeliverKind(i,m,"Request")
OnPrepare(i,m) == DeliverKind(i,m,"Prepare")
OnPrepareOk(i,m) == DeliverKind(i,m,"PrepareOk")
OnCommit(i,m) == DeliverKind(i,m,"Commit")
OnGetState(i,m) == DeliverKind(i,m,"GetState")
OnNewState(i,m) == DeliverKind(i,m,"NewState")
OnStartViewChange(i,m) == DeliverKind(i,m,"StartViewChange")
OnDoViewChange(i,m) == DeliverKind(i,m,"DoViewChange")
OnStartView(i,m) == DeliverKind(i,m,"StartView")
OnRecovery(i,m) == DeliverKind(i,m,"Recovery")
OnRecoveryResponse(i,m) == DeliverKind(i,m,"RecoveryResponse")
OnMessage(i,m) ==
    \/ OnRequest(i,m) \/ OnPrepare(i,m) \/ OnPrepareOk(i,m) \/ OnCommit(i,m)
    \/ OnGetState(i,m) \/ OnNewState(i,m) \/ OnStartViewChange(i,m)
    \/ OnDoViewChange(i,m) \/ OnStartView(i,m) \/ OnRecovery(i,m)
    \/ OnRecoveryResponse(i,m)
\* lib.rs:1233-1285: one owner idle callback, including all synchronous helpers.
OnIdle(i) == /\ i \in live /\ PublishReplica(i,OnIdleState(replicas[i],i),network)

\* lib.rs:274-277,311-326: caller obeys one outstanding request per client.
ClientOnRequest(c,op) ==
    LET e == [client |-> c, number |-> clients[c].next, op |-> op]
        ms == <<[Message("Request",c,Primary(clients[c].view)) EXCEPT !.request=e]>>
    IN /\ clients[c].pending = <<>>
       /\ clients' = [clients EXCEPT ![c].next = @+1, ![c].pending = <<e>>]
       /\ network' = BagAdd(network,ms) /\ lastOutput'=ms
       /\ UNCHANGED <<replicas,durableView,live,incarnations,usedNonces,
                       committedHistory,replyHistory>>
\* lib.rs:353-370: pending retry targets ALL replicas, membership order.
ClientOnIdle(c) ==
    LET ms == IF clients[c].pending= <<>> THEN <<>>
              ELSE [k \in 1..N |-> [Message("Request",c,k-1) EXCEPT
                                                       !.request=Head(clients[c].pending)]]
    IN /\ network'=BagAdd(network,ms) /\ lastOutput'=ms
       /\ UNCHANGED <<replicas,durableView,live,incarnations,usedNonces,
                       clients,committedHistory,replyHistory>>
\* lib.rs:334-347: every reply advances client view, even a stale request reply.
ClientOnReply(c,m) ==
    /\ m \in DOMAIN network /\ m.kind="Reply" /\ m.dst=c
    /\ clients' = [clients EXCEPT ![c].view=Max(@,m.view),
         ![c].pending=IF @ /= <<>> THEN IF Head(@).number=m.request.number THEN <<>> ELSE @ ELSE @]
    /\ network'=BagTake(network,m) /\ lastOutput'= <<>>
    /\ UNCHANGED <<replicas,durableView,live,incarnations,usedNonces,
                    committedHistory,replyHistory>>

\* lib.rs:14-21,505-524: crash erases volatile log/application, keeps durable view.
\* No forgotten persistence, constructor fallback, or reused nonce is introduced.
Crash(i) ==
    /\ i \in live /\ live'=live \ {i}
    /\ replicas'=[replicas EXCEPT ![i]=NewReplica] /\ lastOutput'= <<>>
    /\ UNCHANGED <<durableView,incarnations,usedNonces,clients,network,
                    committedHistory,replyHistory>>
Recover(i,n) ==
    LET s == SendRecovery([NewReplica EXCEPT !.status="Recovering",
               !.view=durableView[i], !.lastNormal=durableView[i], !.nonce=n],i)
    IN /\ i \notin live /\ n \in Nat /\ n \notin usedNonces[i]
       /\ live'=live \cup {i}
       /\ incarnations'=[incarnations EXCEPT ![i]=@+1]
       /\ usedNonces'=[usedNonces EXCEPT ![i]=@ \cup {n}]
       /\ replicas'=[replicas EXCEPT ![i]=[s EXCEPT !.out= <<>>]]
       /\ network'=BagAdd(network,s.out) /\ lastOutput'=s.out
       /\ UNCHANGED <<durableView,clients,committedHistory,replyHistory>>
\* lib.rs:10-12: network losses and duplication are explicit environment actions.
Lose(m) ==
    /\ m \in DOMAIN network /\ network'=BagTake(network,m) /\ lastOutput'= <<>>
    /\ UNCHANGED <<replicas,durableView,live,incarnations,usedNonces,clients,
                    committedHistory,replyHistory>>
Duplicate(m) ==
    /\ m \in DOMAIN network /\ network'=BagAdd(network,<<m>>) /\ lastOutput'= <<>>
    /\ UNCHANGED <<replicas,durableView,live,incarnations,usedNonces,clients,
                    committedHistory,replyHistory>>

\* lib.rs:478-503,292-300: fresh fixed membership and fresh client identities.
Init ==
    /\ replicas=[i \in Servers |-> NewReplica] /\ durableView=[i \in Servers |-> 0]
    /\ live=Servers /\ incarnations=[i \in Servers |-> 0]
    /\ usedNonces=[i \in Servers |-> {}] /\ clients=[c \in Clients |-> NewClient]
    /\ network=EmptyMap /\ committedHistory={} /\ replyHistory={} /\ lastOutput= <<>>
Next ==
    \/ \E i \in Servers : OnIdle(i) \/ Crash(i) \/ Recover(i,incarnations[i]+1)
    \/ \E i \in Servers, m \in DOMAIN network : OnMessage(i,m)
    \/ \E c \in Clients, op \in Operations : ClientOnRequest(c,op)
    \/ \E c \in Clients : ClientOnIdle(c)
    \/ \E c \in Clients, m \in DOMAIN network : ClientOnReply(c,m)
    \/ \E m \in DOMAIN network : Lose(m) \/ Duplicate(m)
Spec == Init /\ [][Next]_vars

\* Brief 5: independent observers, checked after EVERY handler and across time.
CommittedPrefixAgreement ==
    \A a,b \in committedHistory : a.index=b.index => a.request=b.request
CommitBounded == \A i \in Servers : replicas[i].commit <= Len(replicas[i].log)
AppliedPrefix == \A i \in Servers :
    /\ replicas[i].applied=Prefix(replicas[i].log,replicas[i].commit)
    /\ replicas[i].app=Sum(replicas[i].applied)
AtMostOnce == \A i \in Servers :
    \A a,b \in 1..Len(replicas[i].applied) :
      (replicas[i].applied[a].client=replicas[i].applied[b].client /\
       replicas[i].applied[a].number=replicas[i].applied[b].number) => a=b
ReplyCorrect == \A m \in replyHistory : \E h \in committedHistory :
    /\ m.request.client=h.request.client /\ m.request.number=h.request.number
    /\ m.result=h.result
\* Structural checks; callers' filesystem/nonce policies are assumptions above,
\* not claimed implementations of RestartMustRecover/PublishedViewDurable/etc.
TypeOK ==
    /\ live \subseteq Servers /\ DOMAIN replicas=Servers /\ DOMAIN clients=Clients
    /\ durableView \in [Servers -> Nat] /\ incarnations \in [Servers -> Nat]
    /\ usedNonces \in [Servers -> SUBSET Nat]
    /\ \A m \in DOMAIN network : network[m] \in Nat \ {0}
    /\ \A i \in Servers :
        /\ replicas[i].status \in {"Normal","StateTransfer","ViewChange","Recovering"}
        /\ replicas[i].view \in Nat /\ replicas[i].lastNormal \in Nat
        /\ replicas[i].commit \in Nat /\ replicas[i].waiting \in Nat
        /\ replicas[i].attempts \in Nat /\ replicas[i].stable \in Nat
        /\ replicas[i].out= <<>> /\ replicas[i].svc \subseteq Servers
        /\ DOMAIN replicas[i].dvc \subseteq Servers
        /\ DOMAIN replicas[i].responses \subseteq Servers
        /\ \A k \in DOMAIN replicas[i].acks : replicas[i].acks[k] \subseteq Servers
    /\ \A c \in Clients : clients[c].next \in Nat /\ Len(clients[c].pending)<=1
DurableViewConsistent == \A i \in live : durableView[i]=replicas[i].view
=============================================================================
