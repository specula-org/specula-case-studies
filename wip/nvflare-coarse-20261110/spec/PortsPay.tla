------------------------------ MODULE PortsPay ------------------------------
\* Port shapes, message kinds and faults of the PAYLOAD component groups
\* (PaySrc, PayRcv). Owned by the payload component; others only read.
\*
\* Wire encoding (identical in every PaySrc / PayRcv variant; ref = Ref(c, l, a)):
\* PAYLOAD_PULL SJ -> Desc.source, id <<"pull", ref, n, k>>, body [ref, n, try |-> k]
\* (n = receiver request state + 1: 1 = first DATA pull, 2 = EOF pull;
\* k = TIMEOUT retry number of that state, fresh key per try)
\* PAYLOAD_REPLY same id, body [status, value, nonce]; status in
\* {"DATA","EOF","ERROR","PROCESS_EXCEPTION","INVALID_REQUEST"};
\* value = registered value on DATA else None; nonce = serve nonce
\* <<"nonce", c, l, a>> on a provisional EOF/ERROR serve, else None
\* RECEIVER_CONFIRM id <<"confirm", ref, g>>, body [ref, nonce, status in {"success","failed"}]
\* RECEIVER_CANCEL id <<"cancel", ref, g>>, body [ref, status |-> "cancelled"] (no nonce)
\* (g = generation of the descriptor = receiver attempt; the source
\* matches both by body.ref only, as the real wire does)
EXTENDS Consts
PayKinds == {"PAYLOAD_PULL", "PAYLOAD_REPLY", "RECEIVER_CONFIRM", "RECEIVER_CANCEL"}
\* txTimeout : CJ clock advances far enough for tx timeout, drain expiry, receipt TTL
\* pullTimeout: SJ per-request timeouts exhaust max_retries
\* payProduce : producer raises (PROCESS_EXCEPTION) or returns ERROR
\* payConsumer: SJ consumer consume()/download_completed() raises
\* payCallback: a DownloadService user callback / release raises (contained)
\* paySubmit : settlement executor post-enqueue RuntimeError / stopped executor
\* payCompute : outcome computation raises (fail-closed verdict)
\* payDelete : delete_transaction API called by the owner
\* sourceFailure: SJ receives an owned-source failure notice for the ref
\* slowEnvelope lifts timing TA3: an envelope that
\* passed TASK_CHECK reaches the SJ and starts its decode within ~0.1 s, while
\* close -> save -> finalize -> END_RUN -> the SJ's DS shutdown takes >= 1.9 s; so
\* by default no result download registers after the SJ's DS shutdown.
PayFaults == {"pullTimeout", "txTimeout", "payProduce", "payConsumer", "payCallback",
              "paySubmit", "payCompute", "payDelete", "sourceFailure", "slowEnvelope"}
\* Slice identity sets of the payload seed (one ref, one receiver), at Ports
\* level so that mix-root binders can name them (PaySrc_F/PayRcv_F ASSUME
\* they equal the seed's Pairs/Actors/...).
PayRefs == {"ref-1"}
PayReceivers == {"SJ"}
PayPairs == PayRefs \X PayReceivers
PayPullers == {<<"pull", p[1], p[2]>> : p \in PayPairs}
PayConfirmers == {<<"confirm", p[1], p[2]>> : p \in PayPairs}
PayCancellers == {<<"cancel", "-", r>> : r \in PayReceivers}
PayFinalizers == PayConfirmers \cup PayCancellers \cup {<<"budget", "-", "-">>}
PaySettlers == {<<"inline", "-", "-">>, <<"worker", "-", "-">>}
PayActors == PayPullers \cup PayFinalizers \cup PaySettlers
\* One result transaction per (site, launch, attempt); attempt = FedAvg round
\* (Assignment(c, a).attempt). The descriptor ref Ref(c, l, a) carries the
\* attempt, so every wire id (PULL/REPLY <<"pull", ref, n, k>>, CONFIRM/CANCEL
\* <<kind, ref, g>>) and the serve nonce <<"nonce", c, l, a>> are per transaction:
\* retries and later rounds never collide with an earlier transaction's keys.
\* pPaySrc[c][l].tx[a]: registered: None | [ref, source, launch, value];
\* outcome: "none" | recorded receipt status ("completed"/"failed"/"aborted");
\* released: source reference dropped. (settlement_complete is PaySrc-private.)
\* shut: the CJ's DownloadService.shutdown() has torn this transaction down
\* (return side of the call RunCJ declares as pRunCJ.dsDown; RunCJ waits for it).
\* pPaySrc[c][l].registered / .outcome / .released: compatibility view = the
\* fields of the latest registered attempt of launch l (with MaxAttempt = 1
\* exactly the former one-transaction-per-launch port). Written only through
\* SrcTxSet, so every variant produces the same encoding.
SrcTx0 == [registered |-> None, outcome |-> "none", released |-> FALSE, shut |-> FALSE]
PayMaxOf(S) == CHOOSE a \in S : \A b \in S : b <= a
SrcView(tx) ==
    LET regs == {a \in Attempts : tx[a].registered /= None}
        v == IF regs = {} THEN SrcTx0 ELSE tx[PayMaxOf(regs)]
    IN [tx |-> tx, registered |-> v.registered, outcome |-> v.outcome, released |-> v.released]
PaySrcPortInit == [c \in Sites |-> [l \in Launches |-> SrcView([a \in Attempts |-> SrcTx0])]]
\* pPaySrc after replacing transaction (c, l, a) by record r.
SrcTxSet(pp, c, l, a, r) == [pp EXCEPT ![c][l] = SrcView([pp[c][l].tx EXCEPT ![a] = r])]
\* pPayRcv[c].rx[a]: the receiver attempt for site c's round-a result envelope.
\* want: None | descriptor [ref, source, launch]; status: "none" | "pulling" |
\* "materialized" (download_completed returned) | "failed" (download_object
\* returned without data); materialized: value; returned: download_object has
\* returned (FOBS decode may proceed); fatal: SJ os._exit(1) on a failed decode;
\* sjDown: the SJ's DownloadService.shutdown() has returned (set on every rx at
\* once; return side of pWfSJ.dsShutdown, the SJ exit waits for it).
\* pPayRcv[c].want / .materialized / .status / .returned: compatibility view =
\* the latest accepted round's receiver; pPayRcv[c].fatal = some round's decode
\* was fatal (read by Ports!SJFatal). Written only through RcvRxSet.
RcvRx0 == [want |-> None, materialized |-> None, status |-> "none", returned |-> FALSE,
           fatal |-> FALSE, sjDown |-> FALSE]
RcvView(rx) ==
    LET acc == {a \in Attempts : rx[a].want /= None}
        v == IF acc = {} THEN RcvRx0 ELSE rx[PayMaxOf(acc)]
    IN [rx |-> rx, want |-> v.want, materialized |-> v.materialized, status |-> v.status,
        returned |-> v.returned, fatal |-> \E a \in Attempts : rx[a].fatal]
PayRcvPortInit == [c \in Sites |-> RcvView([a \in Attempts |-> RcvRx0])]
\* pPayRcv after replacing receiver attempt (c, a) by record r.
RcvRxSet(pr, c, a, r) == [pr EXCEPT ![c] = RcvView([pr[c].rx EXCEPT ![a] = r])]
\* pPayRcv after the SJ's DownloadService.shutdown() returned.
RcvAllDown(pr) == [c \in Sites |-> RcvView([a \in Attempts |-> [pr[c].rx[a] EXCEPT !.sjDown = TRUE]])]
=============================================================================
