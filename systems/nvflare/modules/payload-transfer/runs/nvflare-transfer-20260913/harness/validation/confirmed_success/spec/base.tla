------------------------------- MODULE base -------------------------------
EXTENDS Naturals, Integers, FiniteSets, Sequences, TLC

\* Source pin: 53ba7ee567468ea7971dad4faccef13c6cb35dc2.
\* Category A, with explicit threaded continuation state (brief sections 1-4).
\* Unqualified source files are nvflare/fuel/f3/streaming/*.py, except the
\* explicitly named client/cell/api.py and Python concurrent/futures/thread.py.
\* One fixed, nonempty transaction is initialized AFTER registration and BEFORE
\* payload exposure. Cooperative, confirm-capable peers and progress_cb enabled.
\* download_service.py:78-82; transfer_outcome.py:34-45. No late registration.
\* ChunkCount ordinary DATA replies followed by EOF; no transport/retry internals.
CONSTANTS Refs, RefOrder, Receivers, ChunkCount, AcquireTimeout, IdleTimeout,
          TxTimeout, DrainTimeout, ReceiptTTL, MinReceivers, FirstRegisteredRef, FinishedRefsTTL
ASSUME /\ IsFiniteSet(Refs) /\ Refs # {} /\ IsFiniteSet(Receivers) /\ Receivers # {}
       /\ FirstRegisteredRef \in Refs
       /\ RefOrder \in Seq(Refs) /\ Len(RefOrder) = Cardinality(Refs)
       /\ {RefOrder[i] : i \in 1..Len(RefOrder)} = Refs
       /\ ChunkCount \in Nat /\ AcquireTimeout \in Nat /\ IdleTimeout \in Nat
       /\ TxTimeout \in Nat \ {0} /\ DrainTimeout \in Nat \ {0}
       /\ FinishedRefsTTL \in Nat \ {0}
       /\ ReceiptTTL \in Nat \ {0} /\ MinReceivers \in 1..Cardinality(Receivers)
\* Zero disables a receiver budget only; the code uses None for this case.
OneRefOrder == <<FirstRegisteredRef>>
TwoRefOrder == <<FirstRegisteredRef, CHOOSE r \in Refs : r # FirstRegisteredRef>>
DefaultRefOrder == TwoRefOrder
Pairs == Refs \X Receivers
\* download_service.py:754,793-801: every refs loop preserves registration order.
FirstRef(rs) == RefOrder[CHOOSE i \in 1..Len(RefOrder) :
    RefOrder[i] \in rs /\ \A j \in 1..(i-1) : RefOrder[j] \notin rs]
Pull(p) == <<"pull", p[1], p[2]>>
Confirm(p) == <<"confirm", p[1], p[2]>>
Cancel(c) == <<"cancel", "-", c>>
Budget == <<"budget", "-", "-">>
Inline == <<"inline", "-", "-">>
Worker == <<"worker", "-", "-">>
Pullers == {Pull(p) : p \in Pairs}
Confirmers == {Confirm(p) : p \in Pairs}
Cancellers == {Cancel(c) : c \in Receivers}
Finalizers == Confirmers \cup Cancellers \cup {Budget}
Settlers == {Inline, Worker}
Actors == Pullers \cup Finalizers \cup Settlers
Pair(t) == <<t[2], t[3]>>
FinalStatuses == {"none", "success", "failed"}
TerminalStates == {"completed", "failed", "aborted"}
ProgressStates == TerminalStates \cup {"active", "none"}
\* Sentinel keys are outside configured identities; not real receivers/refs.
NullPair == <<"-", "-">>
EmptyMatrix == [p \in Pairs |-> "none"]
\* download_service.py:359-367,875-893: completion counts any final truth,
\* including FAILED, but requires every DECLARED receiver on every fixed ref.
RefFinished(m, r) == \A c \in Receivers : m[<<r,c>>] # "none"
Finished(m) == \A r \in Refs : RefFinished(m, r)
\* transfer_outcome.py:185-202,242-259: full receiver truth outranks known cause.
AllSucceeded(m) == \A p \in Pairs : m[p] = "success"
CommonSuccess(m) == {c \in Receivers : \A r \in Refs : m[<<r,c>>] = "success"}
Verdict(m, cause) ==
    [status |-> IF AllSucceeded(m) THEN "completed"
               ELSE IF cause = "deleted" THEN "aborted" ELSE "failed",
     reason |-> IF AllSucceeded(m) THEN "all_receivers_succeeded"
               ELSE IF cause = "deleted" THEN "deleted"
               ELSE IF cause = "timeout" THEN "timeout" ELSE "receiver_failed",
     done |-> cause, matrix |-> m, refsPresent |-> TRUE,
     quorum |-> Cardinality(CommonSuccess(m)) >= MinReceivers]
\* download_service.py:803-820,929-933: compute Exception takes fail-closed route.
FailedVerdict(cause) == [status |-> "failed", reason |-> "computation_failed",
                       done |-> cause, matrix |-> EmptyMatrix,
                       refsPresent |-> FALSE, quorum |-> FALSE]
EmptyVerdict == [status |-> "none", reason |-> "none", done |-> "none",
                matrix |-> EmptyMatrix, refsPresent |-> FALSE, quorum |-> FALSE]
\* transfer_outcome.py:71-79: progress reflects termination cause, not verdict.
DoneProgress(cause) == CASE cause = "finished" -> "completed"
                           [] cause = "timeout" -> "failed"
                           [] OTHER -> "aborted"
Event(p, state, seq, bytes) == [pair |-> p, state |-> state, seq |-> seq, bytes |-> bytes]
EmptyEvent == Event(NullPair, "none", 0, 0)
EmptyPub == [pc |-> "idle", pair |-> NullPair, want |-> "none", delta |-> 0,
             force |-> FALSE, events |-> {}, current |-> EmptyEvent]
RequestPub(p, state, delta, force) ==
    [EmptyPub EXCEPT !.pc = "make", !.pair = p, !.want = state,
                    !.delta = delta, !.force = force]
EmptyCB == [pc |-> "idle", kind |-> "none", ref |-> "-"]
Callback(kind, r) == [pc |-> "ready", kind |-> kind, ref |-> r]
\* Single state record makes every action's unchanged fields explicit via EXCEPT.
VARIABLE st
vars == <<st>>
\* download_service.py:582-592,549-564: terminal callback lists preserve the
\* insertion order of per-ref receiver progress dictionaries.
ProgressRank(p) == CHOOSE i \in 1..Len(st.progressOrder[p[1]]) : st.progressOrder[p[1]][i] = p[2]
FirstProgressEvent(es) == CHOOSE e \in es : \A q \in es : ProgressRank(e.pair) <= ProgressRank(q.pair)
\* download_service.py:342-356,958-989: actual user-hook arguments, projected
\* to one normalized transaction id and source-reference presence/identity.
CallbackArgs(t) ==
    CASE st.cb[t].kind = "one" -> [receiver |-> st.fp[t][2], status |-> st.status[st.fp[t]]]
      [] st.cb[t].kind \in {"all", "release"} -> <<>>
      [] st.cb[t].kind = "objectDone" -> [tx |-> "tx", status |-> st.cause]
      [] st.cb[t].kind = "txDone" -> [tx |-> "tx", status |-> st.cause, sources |-> st.baseObjects[t]]
      [] st.cb[t].kind = "outcome" -> st.verdicts[t]
      [] OTHER -> <<>>
\* S1: truth/pending, Consumer, admitted pulls, finalizers and terminal latch.
\* S2: full matrix and frozen verdicts. S4: distinct tx/ref/receiver activity.
\* S3/S5: queue versus submit acknowledgement, two settlement continuations,
\* callback/release counts, receipt ownership and waiter observations.
Init ==
    \* download_service.py:270-298,700-772,1349-1374,1544-1565: registered payload,
    \* first waiter already attached. Observer fields start empty/zero.
    st = [now |-> 0, live |-> TRUE, owner |-> TRUE, closed |-> FALSE,
          terminating |-> FALSE, settlementComplete |-> FALSE, shutdown |-> FALSE,
          status |-> EmptyMatrix, provisional |-> EmptyMatrix, pending |-> [p \in Pairs |-> FALSE],
          allDone |-> [r \in Refs |-> FALSE], acquired |-> {},
          txLast |-> 0, receiverLast |-> [c \in Receivers |-> -1],
          refLast |-> [p \in Pairs |-> -1], ops |-> {},
          futureStarted |-> [p \in Pairs |-> FALSE], tombstoneAt |-> -1,
          pullPC |-> [p \in Pairs |-> "idle"], pullTime |-> [p \in Pairs |-> 0],
          index |-> [p \in Pairs |-> 0], rc |-> [p \in Pairs |-> "none"],
          nonce |-> [p \in Pairs |-> FALSE], reply |-> [p \in Pairs |-> "none"],
          replyNonce |-> [p \in Pairs |-> FALSE],
          consumer |-> [p \in Pairs |-> "new"], consumerResult |-> EmptyMatrix,
          consumerNonce |-> [p \in Pairs |-> FALSE], abandoned |-> {},
          confirmWire |-> {}, cancelWire |-> {},
          fpc |-> [t \in Finalizers |-> "idle"],
          fp |-> [t \in Finalizers |-> NullPair],
          ftodo |-> [t \in Finalizers |-> {}],
          fwon |-> [t \in Finalizers |-> FALSE],
          faccepted |-> [t \in Finalizers |-> FALSE],
          fall |-> [t \in Finalizers |-> FALSE], finishReady |-> {},
          budgetLast |-> [c \in Receivers |-> -1], budgetNow |-> 0,
          monitorPC |-> "idle", monitorNow |-> 0,
          progressStarted |-> {}, progressOrder |-> [r \in Refs |-> <<>>], progressTerminal |-> [p \in Pairs |-> "none"],
          progressBytes |-> [p \in Pairs |-> 0], progressSeq |-> [p \in Pairs |-> 0],
          refTerminal |-> [r \in Refs |-> "none"],
          observedTerminal |-> [p \in Pairs |-> "none"],
          pub |-> [t \in Actors |-> EmptyPub], cb |-> [t \in Actors |-> EmptyCB],
          cause |-> "none", queued |-> FALSE, submitPC |-> "idle",
          spc |-> [t \in Settlers |-> "idle"],
          drainAt |-> [t \in Settlers |-> 0],
          drainForced |-> [t \in Settlers |-> FALSE],
          todo |-> [t \in Settlers |-> {}],
          snapshots |-> [t \in Settlers |-> EmptyMatrix],
          verdicts |-> [t \in Settlers |-> EmptyVerdict],
          baseObjects |-> [t \in Settlers |-> [r \in Refs |-> FALSE]],
          sourceHeld |-> [r \in Refs |-> TRUE],
          objectDoneCalls |-> [r \in Refs |-> 0], doneCalls |-> 0,
          outcomeCbCalls |-> 0, releaseAttempts |-> [r \in Refs |-> 0],
          effectsAfterReceipt |-> FALSE, callbackErrors |-> 0,
          receiptWrites |-> 0, receipt |-> EmptyVerdict, retained |-> FALSE,
          recordAt |-> 0, recordedBy |-> Inline,
          markerLeaked |-> [t \in Settlers |-> FALSE], waiter |-> "pending", waiterOutcome |-> EmptyVerdict,
          lateWaiter |-> "unregistered", lateOutcome |-> EmptyVerdict,
          caller |-> "waiting"]

\* download_service.py:2164-2182,2203-2209: send the initial ordinary pull
DownloadObjectStart(p) ==
    \* download_service.py:2164-2182,2203-2209: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "new"
    /\ p[2] \notin st.abandoned
    \* download_service.py:2164-2182,2203-2209: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.consumer[p] = "waiting",
          !.futureStarted[p] = TRUE,
          !.pullPC[p] = "sent"]

\* download_service.py:1681-1699,822-833: admit a pull while holding the table and operation locks
HandleDownloadBegin(p) ==
    \* download_service.py:1681-1699,822-833: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "sent"
    /\ st.live
    /\ ~st.closed
    /\ st.futureStarted[p]
    \* download_service.py:1681-1699,822-833: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.ops = @ \cup {Pull(p)},
          !.pullPC[p] = "markTx"]

\* download_service.py:1681-1697: after ref retirement, return retained finished status or missing-ref error; includes a late first acquisition
HandleDownloadMissing(p) ==
    \* download_service.py:1681-1697: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "sent"
    /\ ~st.live \/ st.closed
    /\ st.futureStarted[p]
    \* download_service.py:1681-1697: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pullPC[p] = "done",
          !.reply[p] = IF ~st.shutdown /\ st.tombstoneAt >= 0 /\ st.now - st.tombstoneAt <= FinishedRefsTTL THEN (IF st.status[p] = "success" THEN "eof" ELSE "error") ELSE "missing",
          !.replyNonce[p] = FALSE]

\* download_service.py:1701,300-301,774-775: update the sliding global inactivity clock
HandleDownloadMarkActive(p) ==
    \* download_service.py:1701,300-301,774-775: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "markTx"
    \* download_service.py:1701,300-301,774-775: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.txLast = st.now,
          !.pullPC[p] = "markRef"]

\* download_service.py:441-444,1702: capture request time and publish ref activity under progress lock
RefMarkReceiverActive(p) ==
    \* download_service.py:441-444,1702: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "markRef"
    \* download_service.py:441-444,1702: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pullTime[p] = st.now,
          !.refLast[p] = st.now,
          !.pullPC[p] = "markReceiver"]

\* download_service.py:445-450: publish the same captured time under transaction stats lock
TransactionMarkReceiverActive(p) ==
    \* download_service.py:445-450: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "markReceiver"
    \* download_service.py:445-450: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.receiverLast[p[2]] = st.pullTime[p],
          !.acquired = @ \cup {p[2]},
          !.pullPC[p] = "startProgress"]

\* download_service.py:1703,517-542: request ACTIVE progress before produce
HandleDownloadActiveProgress(p) ==
    \* download_service.py:1703,517-542: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "startProgress"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1703,517-542: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pub[Pull(p)] = RequestPub(p, "active", 0, FALSE),
          !.pullPC[p] = "produce"]

\* download_service.py:1707-1716,1724,1751-1775: ordinary produce returns DATA then EOF; transport contents abstracted
HandleDownloadProduce(p) ==
    \* download_service.py:1707-1716,1724,1751-1775: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "produce"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1707-1716,1724,1751-1775: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.rc[p] = IF st.index[p] < ChunkCount THEN "data" ELSE "eof",
          !.pullPC[p] = IF st.index[p] < ChunkCount THEN "dataProgress" ELSE "served"]

\* download_service.py:1715-1722: ordinary produce exception prepares FAILED progress and PROCESS_EXCEPTION
HandleDownloadProduceException(p) ==
    \* download_service.py:1715-1722: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "produce"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1715-1722: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.rc[p] = "exception",
          !.pub[Pull(p)] = RequestPub(p, "failed", 0, TRUE),
          !.pullPC[p] = "end"]

\* download_service.py:369-397,1728-1732: record a provisional serve or return no nonce when already final
RefObjServed(p) ==
    \* download_service.py:369-397,1728-1732: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "served"
    \* download_service.py:369-397,1728-1732: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.provisional[p] = IF st.status[p] = "none" THEN (IF st.rc[p] = "eof" THEN "success" ELSE "failed") ELSE "none",
          !.pending[p] = st.status[p] = "none",
          !.nonce[p] = st.status[p] = "none",
          !.pullPC[p] = "terminalProgress"]

\* download_service.py:1733-1749: choose progress from returned serve nonce and producer RC, outside progress lock
HandleDownloadTerminalProgress(p) ==
    \* download_service.py:1733-1749: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "terminalProgress"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1733-1749: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pub[Pull(p)] = RequestPub(p, IF st.nonce[p] THEN "active" ELSE IF st.rc[p] = "eof" THEN "completed" ELSE "failed", 0, TRUE),
          !.pullPC[p] = "end"]

\* download_service.py:1752-1775: count one abstract data unit and prepare ACTIVE progress
HandleDownloadDataProgress(p) ==
    \* download_service.py:1752-1775: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "dataProgress"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1752-1775: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pub[Pull(p)] = RequestPub(p, "active", 1, FALSE),
          !.nonce[p] = FALSE,
          !.pullPC[p] = "end"]

\* download_service.py:1750,1768-1779,835-839: finally leaves the operation gate before the reply becomes receivable
HandleDownloadEndOp(p) ==
    \* download_service.py:1750,1768-1779,835-839: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "end"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1750,1768-1779,835-839: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.ops = @ \ {Pull(p)},
          !.pullPC[p] = "done",
          !.reply[p] = st.rc[p],
          !.replyNonce[p] = st.nonce[p]]

\* download_service.py:2212-2213,2291-2298: receive DATA and remember cancel capability; one unit consumed next
ConsumerReceiveData(p) ==
    \* download_service.py:2212-2213,2291-2298: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "waiting"
    /\ st.reply[p] = "data"
    \* download_service.py:2212-2213,2291-2298: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.reply[p] = "none",
          !.consumer[p] = "data",
          !.index[p] = @ + 1]

\* download_service.py:2300-2305: submit next request BEFORE calling consume on the current data
ConsumerLaunchPipeline(p) ==
    \* download_service.py:2300-2305: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "data"
    /\ st.pullPC[p] = "done"
    \* download_service.py:2300-2305: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.consumer[p] = "consuming",
          !.futureStarted[p] = FALSE,
          !.pullPC[p] = "sent"]

\* download_service.py:2309-2310,2333-2349: value-stable consume returns; wait for the already submitted request
ConsumerConsumeReturn(p) ==
    \* download_service.py:2309-2310,2333-2349: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "consuming"
    \* download_service.py:2309-2310,2333-2349: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.consumer[p] = "waiting"]

\* download_service.py:2311-2317: consume raises; cancel an unstarted future, but an admitted request keeps running
ConsumerConsumeException(p) ==
    \* download_service.py:2311-2317: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "consuming"
    \* download_service.py:2311-2317: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.consumer[p] = "failed",
          !.consumerResult[p] = "failed",
          !.abandoned = @ \cup {p[2]},
          !.cancelWire = @ \cup {p[2]},
          !.pullPC[p] = IF ~st.futureStarted[p] THEN "done" ELSE @]

\* download_service.py:2260-2274: receive EOF and enter download_completed before sending any confirmation
ConsumerReceiveEOF(p) ==
    \* download_service.py:2260-2274: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "waiting"
    /\ st.reply[p] = "eof"
    \* download_service.py:2260-2274: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.reply[p] = "none",
          !.consumerNonce[p] = st.replyNonce[p],
          !.consumer[p] = "completing"]

\* download_service.py:2273-2283: download_completed returns successfully
ConsumerDownloadCompleted(p) ==
    \* download_service.py:2273-2283: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "completing"
    \* download_service.py:2273-2283: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.consumerResult[p] = "success",
          !.consumer[p] = "confirmReady"]

\* download_service.py:2273-2281: download_completed raises and schedules FAILED confirmation
ConsumerDownloadCompletedException(p) ==
    \* download_service.py:2273-2281: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "completing"
    \* download_service.py:2273-2281: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.consumerResult[p] = "failed",
          !.consumer[p] = "confirmReady"]

\* download_service.py:2083-2105,2279-2283: send receiver truth only if terminal reply requested nonce-bound confirmation
ConsumerSendConfirm(p) ==
    \* download_service.py:2083-2105,2279-2283: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "confirmReady"
    \* download_service.py:2083-2105,2279-2283: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.confirmWire = IF st.consumerNonce[p] THEN @ \cup {p} ELSE @,
          !.consumer[p] = "done"]

\* download_service.py:2221-2250: ordinary failed request causes cancellation after acquisition
ConsumerReceiveError(p) ==
    \* download_service.py:2221-2250: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "waiting"
    /\ st.reply[p] \in {"exception", "missing"}
    \* download_service.py:2221-2250: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.reply[p] = "none",
          !.consumer[p] = "failed",
          !.consumerResult[p] = "failed",
          !.abandoned = @ \cup {p[2]},
          !.cancelWire = IF st.index[p] > 0 THEN @ \cup {p[2]} ELSE @]

\* download_service.py:2083-2105,456-469: best-effort confirmation fails to arrive; receiver budgets remain the backstop
LoseConfirmation(p) ==
    \* download_service.py:2083-2105,456-469: control-flow guards / captured local decisions.
    /\ p \in st.confirmWire
    \* download_service.py:2083-2105,456-469: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.confirmWire = @ \ {p}]

\* download_service.py:1782-1799,822-833: admit confirmation, preserving nonce requirement for the later final-status lock
HandleConfirmBegin(p) ==
    \* download_service.py:1782-1799,822-833: control-flow guards / captured local decisions.
    /\ p \in st.confirmWire
    /\ st.fpc[Confirm(p)] = "idle"
    /\ st.live
    /\ ~st.closed
    \* download_service.py:1782-1799,822-833: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.confirmWire = @ \ {p},
          !.ops = @ \cup {Confirm(p)},
          !.ftodo[Confirm(p)] = {p},
          !.fpc[Confirm(p)] = "select"]

\* download_service.py:1783-1793: drop confirmation after retirement/closed gate
HandleConfirmLate(p) ==
    \* download_service.py:1783-1793: control-flow guards / captured local decisions.
    /\ p \in st.confirmWire
    /\ ~st.live \/ st.closed
    \* download_service.py:1783-1793: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.confirmWire = @ \ {p}]

\* download_service.py:1814-1827,822-833: admit cancellation before testing transaction-level acquisition
HandleCancelBegin(c) ==
    \* download_service.py:1814-1827,822-833: control-flow guards / captured local decisions.
    /\ c \in st.cancelWire
    /\ st.fpc[Cancel(c)] = "idle"
    /\ st.live
    /\ ~st.closed
    \* download_service.py:1814-1827,822-833: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cancelWire = @ \ {c},
          !.ops = @ \cup {Cancel(c)},
          !.fpc[Cancel(c)] = "acquired"]

\* download_service.py:1816-1822: drop cancellation after retirement/closed gate
HandleCancelLate(c) ==
    \* download_service.py:1816-1822: control-flow guards / captured local decisions.
    /\ c \in st.cancelWire
    /\ ~st.live \/ st.closed
    \* download_service.py:1816-1822: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cancelWire = @ \ {c}]

\* download_service.py:1828-1839: snapshot acquired membership, then iterate all fixed sibling refs
HandleCancelAcquired(c) ==
    \* download_service.py:1828-1839: control-flow guards / captured local decisions.
    /\ st.fpc[Cancel(c)] = "acquired"
    \* download_service.py:1828-1839: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.ftodo[Cancel(c)] = IF c \in st.acquired THEN {<<r,c>> : r \in Refs} ELSE {},
          !.fpc[Cancel(c)] = "select"]

\* download_service.py:1799,1838-1839,306-308: select the next ref before acquiring its progress lock
FinalizerSelectRef(t, p) ==
    \* download_service.py:1799,1838-1839,306-308: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "select"
    /\ p \in st.ftodo[t]
    /\ p[1] = FirstRef({q[1] : q \in st.ftodo[t]})
    \* download_service.py:1799,1838-1839,306-308: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.fp[t] = p,
          !.ftodo[t] = @ \ {p},
          !.fpc[t] = "commit"]

\* download_service.py:313-335: atomic dedup, pending guard, pop, status record and downloaded_to_all latch
RefFinalizeReceiverCommit(t) ==
    LET p == st.fp[t]
        value == IF t \in Confirmers THEN st.consumerResult[p] ELSE "failed"
        won == st.status[p] = "none" /\ (t \notin Confirmers \/ (st.pending[p] /\ st.consumerNonce[p]))
        m == IF won THEN [st.status EXCEPT ![p] = value] ELSE st.status
        all == won /\ ~st.allDone[p[1]] /\ RefFinished(m, p[1])
    IN
    \* download_service.py:313-335: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "commit"
    \* download_service.py:313-335: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.status = m,
          !.provisional[p] = IF won THEN "none" ELSE @,
          !.pending[p] = IF won THEN FALSE ELSE @,
          !.allDone[p[1]] = @ \/ all,
          !.fwon[t] = won,
          !.faccepted[t] = @ \/ won,
          !.fall[t] = all,
          !.cb[t] = IF won THEN Callback("one", p[1]) ELSE @,
          !.fpc[t] = IF won THEN "one" ELSE "advance"]

\* download_service.py:342-357: after guarded downloaded_to_one, independently invoke downloaded_to_all if latched
RefDownloadedToOneReturned(t) ==
    \* download_service.py:342-357: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "one"
    /\ st.cb[t].pc = "done"
    \* download_service.py:342-357: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = IF st.fall[t] THEN Callback("all", st.fp[t][1]) ELSE EmptyCB,
          !.fpc[t] = IF st.fall[t] THEN "all" ELSE "progress"]

\* download_service.py:350-357: guarded downloaded_to_all returns to the caller
RefDownloadedToAllReturned(t) ==
    \* download_service.py:350-357: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "all"
    /\ st.cb[t].pc = "done"
    \* download_service.py:350-357: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = EmptyCB,
          !.fpc[t] = "progress"]

\* download_service.py:411-429,510-514: after callback return select receiver truth for progress (separate from final commit)
RefFinalizerProgress(t) ==
    \* download_service.py:411-429,510-514: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "progress"
    /\ st.pub[t].pc = "idle"
    \* download_service.py:411-429,510-514: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pub[t] = RequestPub(st.fp[t], IF st.status[st.fp[t]] = "success" THEN "completed" ELSE "failed", 0, TRUE),
          !.fpc[t] = "advance"]

\* download_service.py:423-430,504-515,1799-1801,1838-1839: after receiver publication return to the sibling/candidate loop
FinalizerAdvance(t) ==
    \* download_service.py:423-430,504-515,1799-1801,1838-1839: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "advance"
    /\ st.pub[t].pc = "idle"
    \* download_service.py:423-430,504-515,1799-1801,1838-1839: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.fpc[t] = "select"]

\* download_service.py:1799-1803: accepted confirmation refreshes transaction clock only, after its callbacks
HandleConfirmMarkActive(p) ==
    \* download_service.py:1799-1803: control-flow guards / captured local decisions.
    /\ st.fpc[Confirm(p)] = "select"
    /\ st.ftodo[Confirm(p)] = {}
    \* download_service.py:1799-1803: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.txLast = IF st.faccepted[Confirm(p)] THEN st.now ELSE @,
          !.fpc[Confirm(p)] = "end"]

\* download_service.py:1838-1841: all sibling cancellation attempts returned
HandleCancelLoopDone(c) ==
    \* download_service.py:1838-1841: control-flow guards / captured local decisions.
    /\ st.fpc[Cancel(c)] = "select"
    /\ st.ftodo[Cancel(c)] = {}
    \* download_service.py:1838-1841: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.fpc[Cancel(c)] = "end"]

\* download_service.py:1802-1810,1840-1844,835-839: end operation BEFORE requesting finish-if-complete
FinalizerEndOp(t) ==
    \* download_service.py:1802-1810,1840-1844,835-839: control-flow guards / captured local decisions.
    /\ st.fpc[t] = "end"
    \* download_service.py:1802-1810,1840-1844,835-839: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.ops = @ \ {t},
          !.fpc[t] = "done",
          !.finishReady = IF st.faccepted[t] THEN @ \cup {t} ELSE @]

\* download_service.py:1848-1863: capture monitor time before budget operations; no absolute transaction-age deadline
MonitorBegin ==
    \* download_service.py:1848-1863: control-flow guards / captured local decisions.
    /\ st.monitorPC = "idle"
    /\ st.live
    /\ ~st.shutdown
    \* download_service.py:1848-1863: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.monitorNow = st.now,
          !.monitorPC = "admit"]

\* download_service.py:1856-1865,822-833: register budget pass as an operation if the transaction is still live
MonitorAdmitBudgets ==
    \* download_service.py:1856-1865,822-833: control-flow guards / captured local decisions.
    /\ st.monitorPC = "admit"
    \* download_service.py:1856-1865,822-833: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.ops = IF st.live /\ ~st.closed /\ (AcquireTimeout > 0 \/ IdleTimeout > 0) THEN @ \cup {Budget} ELSE @,
          !.fpc[Budget] = IF st.live /\ ~st.closed /\ (AcquireTimeout > 0 \/ IdleTimeout > 0) THEN "snapshot" ELSE @,
          !.monitorPC = IF st.live /\ ~st.closed /\ (AcquireTimeout > 0 \/ IdleTimeout > 0) THEN "budget" ELSE "classify"]

\* download_service.py:857-873: capture receiver activity once per transaction budget pass under stats lock
EnforceReceiverBudgetsSnapshot ==
    \* download_service.py:857-873: control-flow guards / captured local decisions.
    /\ st.fpc[Budget] = "snapshot"
    \* download_service.py:857-873: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.budgetLast = st.receiverLast,
          !.budgetNow = st.monitorNow,
          !.ftodo[Budget] = Pairs,
          !.fpc[Budget] = "select",
          !.faccepted[Budget] = FALSE]

\* download_service.py:475-502: select a candidate from declared identities; test acquisition/idle using captured receiver clock
RefEnforceBudgetSelect(p) ==
    LET last == st.budgetLast[p[2]]
        eligible == st.status[p] = "none" /\
            IF last = -1 THEN AcquireTimeout > 0 /\ st.budgetNow > AcquireTimeout
            ELSE IdleTimeout > 0 /\ st.budgetNow - last > IdleTimeout
    IN
    \* download_service.py:475-502: control-flow guards / captured local decisions.
    /\ st.fpc[Budget] = "select"
    /\ p \in st.ftodo[Budget]
    /\ p[1] = FirstRef({q[1] : q \in st.ftodo[Budget]})
    \* download_service.py:475-502: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.fp[Budget] = p,
          !.ftodo[Budget] = @ \ {p},
          !.fpc[Budget] = IF eligible THEN "recheck" ELSE "select"]

\* download_service.py:504-510: freshness recheck under stats lock; release it BEFORE final-status commit
RefEnforceBudgetRecheck ==
    \* download_service.py:504-510: control-flow guards / captured local decisions.
    /\ st.fpc[Budget] = "recheck"
    \* download_service.py:504-510: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.fpc[Budget] = IF st.receiverLast[st.fp[Budget][2]] = st.budgetLast[st.fp[Budget][2]] THEN "commit" ELSE "select"]

\* download_service.py:1864-1871,835-839: finish all budget callbacks and leave gate before classification
MonitorBudgetEndOp ==
    \* download_service.py:1864-1871,835-839: control-flow guards / captured local decisions.
    /\ st.fpc[Budget] = "select"
    /\ st.ftodo[Budget] = {}
    \* download_service.py:1864-1871,835-839: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.ops = @ \ {Budget},
          !.fpc[Budget] = "idle",
          !.monitorPC = "classify"]

\* download_service.py:1875-1890,1909: classification leaves a live nonexpired transaction, or notices another terminator won
MonitorNoRetirement ==
    \* download_service.py:1875-1890,1909: control-flow guards / captured local decisions.
    /\ st.monitorPC = "classify"
    /\ ~st.live \/ (~Finished(st.status) /\ st.monitorNow - st.txLast <= TxTimeout)
    \* download_service.py:1875-1890,1909: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.monitorPC = "idle"]

\* download_service.py:1411-1425,1525-1541: table-locked single-winner retirement; monotone final-status scan linearizes at successful check
FinishTransactionIfComplete(t) ==
    \* download_service.py:1411-1425,1525-1541: control-flow guards / captured local decisions.
    /\ t \in st.finishReady
    /\ st.live
    /\ Finished(st.status)
    \* download_service.py:1411-1425,1525-1541: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.finishReady = @ \ {t},
          !.live = FALSE,
          !.terminating = TRUE,
          !.cause = "finished",
          !.submitPC = "ready",
          !.tombstoneAt = st.now]

\* download_service.py:1420-1422: helper observes missing transaction or a ref that is not complete
FinishTransactionNotComplete(t) ==
    \* download_service.py:1420-1422: control-flow guards / captured local decisions.
    /\ t \in st.finishReady
    /\ ~st.live \/ ~Finished(st.status)
    \* download_service.py:1420-1422: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.finishReady = @ \ {t}]

\* download_service.py:1875-1890,1903-1907: monitor retires a finished transaction and schedules its own inline settlement
MonitorRetireFinished ==
    \* download_service.py:1875-1890,1903-1907: control-flow guards / captured local decisions.
    /\ st.monitorPC = "classify"
    /\ st.live
    /\ Finished(st.status)
    \* download_service.py:1875-1890,1903-1907: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.live = FALSE,
          !.terminating = TRUE,
          !.cause = "finished",
          !.spc[Inline] = "enter",
          !.monitorPC = "settling",
          !.tombstoneAt = st.now]

\* download_service.py:1880-1887,1897-1901: only after not-finished test, retire on sliding inactivity using monitor sampled time
MonitorRetireTimeout ==
    \* download_service.py:1880-1887,1897-1901: control-flow guards / captured local decisions.
    /\ st.monitorPC = "classify"
    /\ st.live
    /\ ~Finished(st.status)
    /\ st.monitorNow - st.txLast > TxTimeout
    \* download_service.py:1880-1887,1897-1901: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.live = FALSE,
          !.terminating = TRUE,
          !.cause = "timeout",
          !.spc[Inline] = "enter",
          !.monitorPC = "settling"]

\* download_service.py:1399-1408,1525-1541: explicit deletion atomically wins table ownership, then runs settlement outside the lock
DeleteTransaction ==
    \* download_service.py:1399-1408,1525-1541: control-flow guards / captured local decisions.
    /\ st.live
    \* download_service.py:1399-1408,1525-1541: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.live = FALSE,
          !.terminating = TRUE,
          !.cause = "deleted",
          !.spc[Inline] = "enter"]

\* download_service.py:1457-1497: atomically clear ownership and receipts; resolve pending waiters with None BEFORE cleanup
Shutdown ==
    \* download_service.py:1457-1497: control-flow guards / captured local decisions.
    /\ ~st.shutdown
    \* download_service.py:1457-1497: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.shutdown = TRUE,
          !.live = FALSE,
          !.owner = FALSE,
          !.retained = FALSE,
          !.terminating = IF st.live THEN TRUE ELSE @,
          !.cause = IF st.live THEN "deleted" ELSE @,
          !.spc[Inline] = IF st.live THEN "enter" ELSE @,
          !.waiter = IF @ = "pending" THEN "none" ELSE @,
          !.lateWaiter = IF @ = "pending" THEN "none" ELSE @]

\* download_service.py:526-612: construct or suppress a progress event atomically, latching first terminal state
RefMakeProgressEvent(t) ==
    LET p == st.pub[t].pair
        wasTerminal == st.progressTerminal[p] # "none"
        override == st.refTerminal[p[1]] # "none" /\ st.pub[t].want \notin TerminalStates
        state == IF override THEN st.refTerminal[p[1]] ELSE st.pub[t].want
        delta == IF override THEN 0 ELSE st.pub[t].delta
        bytes == st.progressBytes[p] + delta
        emit == ~wasTerminal /\ (override \/ st.pub[t].force \/ p \notin st.progressStarted \/ state \in TerminalStates \/ delta > 0)
    IN
    \* download_service.py:526-612: control-flow guards / captured local decisions.
    /\ st.pub[t].pc = "make"
    \* download_service.py:526-612: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.progressStarted = @ \cup {p},
          !.progressOrder[p[1]] = IF p \notin st.progressStarted THEN Append(@, p[2]) ELSE @,
          !.progressBytes[p] = IF wasTerminal THEN @ ELSE bytes,
          !.progressSeq[p] = IF emit THEN @ + 1 ELSE @,
          !.progressTerminal[p] = IF emit /\ state \in TerminalStates THEN state ELSE @,
          !.pub[t].pc = IF emit THEN "call" ELSE "idle",
          !.pub[t].events = IF emit THEN {Event(p, state, st.progressSeq[p]+1, bytes)} ELSE {}]

\* download_service.py:539-542,1004-1013: invoke public source progress callback after releasing progress lock
TransactionEmitProgressEvent(t, e) ==
    \* download_service.py:539-542,1004-1013: control-flow guards / captured local decisions.
    /\ st.pub[t].pc = "call"
    /\ e = FirstProgressEvent(st.pub[t].events)
    \* download_service.py:539-542,1004-1013: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pub[t].events = @ \ {e},
          !.pub[t].current = e,
          !.pub[t].pc = "return",
          !.observedTerminal[e.pair] = IF e.state \in TerminalStates THEN e.state ELSE @]

\* download_service.py:1008-1013: progress callback returns or its ordinary Exception is contained; no unmodeled callback mutation
TransactionProgressCallbackReturn(t) ==
    \* download_service.py:1008-1013: control-flow guards / captured local decisions.
    /\ st.pub[t].pc = "return"
    \* download_service.py:1008-1013: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.pub[t].pc = IF st.pub[t].events = {} THEN "idle" ELSE "call",
          !.pub[t].current = EmptyEvent]

\* stream_utils.py:60-78; concurrent/futures/thread.py:199-216: enqueue settlement before submission acknowledgement (brief S3; saved stdlib evidence)
CheckedExecutorEnqueue ==
    \* stream_utils.py:60-78; concurrent/futures/thread.py:199-216: control-flow guards / captured local decisions.
    /\ st.submitPC = "ready"
    \* stream_utils.py:60-78; concurrent/futures/thread.py:199-216: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.queued = TRUE,
          !.submitPC = "enqueued"]

\* stream_utils.py:65-66; concurrent/futures/thread.py:199-216: return the Future; the worker may already have started
CheckedExecutorSubmitReturn ==
    \* stream_utils.py:65-66; concurrent/futures/thread.py:199-216: control-flow guards / captured local decisions.
    /\ st.submitPC = "enqueued"
    \* stream_utils.py:65-66; concurrent/futures/thread.py:199-216: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.submitPC = "done"]

\* stream_utils.py:71-78; download_service.py:1435-1441: post-enqueue non-shutdown RuntimeError propagates; DownloadService selects fallback without dequeuing
CheckedExecutorSubmitRuntimeError ==
    \* stream_utils.py:71-78; download_service.py:1435-1441: control-flow guards / captured local decisions.
    /\ st.submitPC = "enqueued"
    \* stream_utils.py:71-78; download_service.py:1435-1441: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.submitPC = "fallback"]

\* stream_utils.py:61-64,79-81; download_service.py:1442-1446: executor declines submission before enqueue and returns None
CheckedExecutorSubmitStopped ==
    \* stream_utils.py:61-64,79-81; download_service.py:1442-1446: control-flow guards / captured local decisions.
    /\ st.submitPC = "ready"
    \* stream_utils.py:61-64,79-81; download_service.py:1442-1446: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.submitPC = "fallback"]

\* download_service.py:1442-1454: run inline fallback; no settlement-entry dedup latch exists
SubmitFinishedSettlementFallback ==
    \* download_service.py:1442-1454: control-flow guards / captured local decisions.
    /\ st.submitPC = "fallback"
    \* download_service.py:1442-1454: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.submitPC = "done",
          !.spc[Inline] = "enter"]

\* stream_utils.py:65-78,84-85; download_service.py:1449-1454: a runnable worker dequeues the existing settlement item, even if submission reported error
SettleFinishedTransactionWorker ==
    \* stream_utils.py:65-78,84-85; download_service.py:1449-1454: control-flow guards / captured local decisions.
    /\ st.queued
    /\ st.spc[Worker] = "idle"
    \* stream_utils.py:65-78,84-85; download_service.py:1449-1454: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.queued = FALSE,
          !.spc[Worker] = "enter"]

\* download_service.py:895-906,841-850: each settlement invocation independently closes gate and establishes its own drain deadline
TransactionDoneDrainBegin(t) ==
    \* download_service.py:895-906,841-850: control-flow guards / captured local decisions.
    /\ st.spc[t] = "enter"
    \* download_service.py:895-906,841-850: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.closed = TRUE,
          !.drainAt[t] = st.now,
          !.spc[t] = "drain"]

\* download_service.py:841-851,910: drain returns normally once all admitted operations ended
TransactionDoneDrainEmpty(t) ==
    \* download_service.py:841-851,910: control-flow guards / captured local decisions.
    /\ st.spc[t] = "drain"
    /\ st.ops = {}
    \* download_service.py:841-851,910: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.todo[t] = Refs,
          !.spc[t] = "snapshot"]

\* download_service.py:846-849,905-910: after the bounded wait, proceed even with outstanding operations
TransactionDoneDrainExpired(t) ==
    \* download_service.py:846-849,905-910: control-flow guards / captured local decisions.
    /\ st.spc[t] = "drain"
    /\ st.ops # {}
    /\ st.now - st.drainAt[t] >= DrainTimeout
    \* download_service.py:846-849,905-910: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.drainForced[t] = TRUE,
          !.todo[t] = Refs,
          !.spc[t] = "snapshot"]

\* download_service.py:910,918-927,432-434: copy one complete per-ref status map under that ref lock; refs are snapshotted separately
TransactionDoneSnapshotRef(t, r) ==
    \* download_service.py:910,918-927,432-434: control-flow guards / captured local decisions.
    /\ st.spc[t] = "snapshot"
    /\ r \in st.todo[t]
    /\ r = FirstRef(st.todo[t])
    \* download_service.py:910,918-927,432-434: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.snapshots[t] = [p \in Pairs |-> IF p[1] = r THEN st.status[p] ELSE st.snapshots[t][p]],
          !.todo[t] = @ \ {r}]

\* download_service.py:918-928; transfer_outcome.py:156-202,242-271: compute strict success and common-receiver quorum from the frozen matrix
TransactionDoneComputeOutcome(t) ==
    \* download_service.py:918-928; transfer_outcome.py:156-202,242-271: control-flow guards / captured local decisions.
    /\ st.spc[t] = "snapshot"
    /\ st.todo[t] = {}
    \* download_service.py:918-928; transfer_outcome.py:156-202,242-271: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.verdicts[t] = Verdict(st.snapshots[t], st.cause),
          !.spc[t] = "terminalProgress",
          !.todo[t] = Refs]

\* download_service.py:929-933,803-820: contained computation Exception creates an empty fail-closed verdict and still executes cleanup
TransactionDoneComputeException(t) ==
    \* download_service.py:929-933,803-820: control-flow guards / captured local decisions.
    /\ st.spc[t] = "snapshot"
    /\ st.todo[t] = {}
    \* download_service.py:929-933,803-820: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.verdicts[t] = FailedVerdict(st.cause),
          !.spc[t] = "terminalProgress",
          !.todo[t] = Refs]

\* download_service.py:935-938,544-564,576-612: under one ref lock, set ref-wide terminal override and construct all started-receiver events
TransactionDoneTerminalProgress(t, r) ==
    LET state == DoneProgress(st.cause)
        eligible == {p \in st.progressStarted : p[1] = r /\ st.progressTerminal[p] = "none"}
    IN
    \* download_service.py:935-938,544-564,576-612: control-flow guards / captured local decisions.
    /\ st.spc[t] = "terminalProgress"
    /\ r \in st.todo[t]
    /\ st.pub[t].pc = "idle"
    /\ r = FirstRef(st.todo[t])
    \* download_service.py:935-938,544-564,576-612: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.refTerminal[r] = state,
          !.progressTerminal = [p \in Pairs |-> IF p \in eligible THEN state ELSE st.progressTerminal[p]],
          !.progressSeq = [p \in Pairs |-> st.progressSeq[p] + IF p \in eligible THEN 1 ELSE 0],
          !.pub[t] = [EmptyPub EXCEPT !.pc = IF eligible = {} THEN "idle" ELSE "call", !.events = {Event(p, state, st.progressSeq[p]+1, st.progressBytes[p]) : p \in eligible}],
          !.todo[t] = @ \ {r}]

\* download_service.py:935-953: finish terminal progress callbacks before capturing the base objects
TransactionDoneProgressReturned(t) ==
    \* download_service.py:935-953: control-flow guards / captured local decisions.
    /\ st.spc[t] = "terminalProgress"
    /\ st.todo[t] = {}
    /\ st.pub[t].pc = "idle"
    \* download_service.py:935-953: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.spc[t] = "baseObjects",
          !.todo[t] = Refs]

\* download_service.py:948-953: snapshot each infrastructure source reference before object callbacks; another settlement may already release it
TransactionDoneSnapshotBaseObject(t, r) ==
    \* download_service.py:948-953: control-flow guards / captured local decisions.
    /\ st.spc[t] = "baseObjects"
    /\ r \in st.todo[t]
    /\ r = FirstRef(st.todo[t])
    \* download_service.py:948-953: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.baseObjects[t][r] = st.sourceHeld[r],
          !.todo[t] = @ \ {r}]

\* download_service.py:953-955: begin per-object transaction_done callback loop
TransactionDoneObjectsBegin(t) ==
    \* download_service.py:953-955: control-flow guards / captured local decisions.
    /\ st.spc[t] = "baseObjects"
    /\ st.todo[t] = {}
    \* download_service.py:953-955: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.spc[t] = "objects",
          !.todo[t] = Refs]

\* download_service.py:955-964: prepare one guarded object transaction_done callback
TransactionDoneObjectCallback(t, r) ==
    \* download_service.py:955-964: control-flow guards / captured local decisions.
    /\ st.spc[t] = "objects"
    /\ r \in st.todo[t]
    /\ st.cb[t].pc = "idle"
    /\ r = FirstRef(st.todo[t])
    \* download_service.py:955-964: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = Callback("objectDone", r),
          !.todo[t] = @ \ {r}]

\* download_service.py:955-964: return to loop after this object hook returned or raised
TransactionDoneObjectReturned(t) ==
    \* download_service.py:955-964: control-flow guards / captured local decisions.
    /\ st.spc[t] = "objects"
    /\ st.cb[t].pc = "done"
    \* download_service.py:955-964: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = EmptyCB]

\* download_service.py:966-975: invoke configured transaction_done_cb with this invocation's base-object snapshot
TransactionDoneTransactionCallback(t) ==
    \* download_service.py:966-975: control-flow guards / captured local decisions.
    /\ st.spc[t] = "objects"
    /\ st.todo[t] = {}
    /\ st.cb[t].pc = "idle"
    \* download_service.py:966-975: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = Callback("txDone", "-"),
          !.spc[t] = "txCallback"]

\* download_service.py:977-978: after transaction callback return, invoke outcome_cb BEFORE source releases
TransactionDoneOutcomeCallback(t) ==
    \* download_service.py:977-978: control-flow guards / captured local decisions.
    /\ st.spc[t] = "txCallback"
    /\ st.cb[t].pc = "done"
    \* download_service.py:977-978: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = Callback("outcome", "-"),
          !.spc[t] = "outcomeCallback"]

\* download_service.py:977-989: finally begins release loop despite guarded callback Exceptions
TransactionDoneReleaseBegin(t) ==
    \* download_service.py:977-989: control-flow guards / captured local decisions.
    /\ st.spc[t] = "outcomeCallback"
    /\ st.cb[t].pc = "done"
    \* download_service.py:977-989: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = EmptyCB,
          !.todo[t] = Refs,
          !.spc[t] = "release"]

\* download_service.py:985-989: prepare each independently guarded release attempt
TransactionDoneRelease(t, r) ==
    \* download_service.py:985-989: control-flow guards / captured local decisions.
    /\ st.spc[t] = "release"
    /\ r \in st.todo[t]
    /\ st.cb[t].pc = "idle"
    /\ r = FirstRef(st.todo[t])
    \* download_service.py:985-989: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = Callback("release", r),
          !.todo[t] = @ \ {r}]

\* download_service.py:988-989: continue release loop after this source release returned or raised
TransactionDoneReleaseReturned(t) ==
    \* download_service.py:988-989: control-flow guards / captured local decisions.
    /\ st.spc[t] = "release"
    /\ st.cb[t].pc = "done"
    \* download_service.py:988-989: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t] = EmptyCB]

\* download_service.py:645-655,342-356,958-989: enter user hook; observer counts invocations/attempts, independently of return or exception
InvokeCallbackSafely(t, arg) ==
    LET k == st.cb[t].kind
        r == st.cb[t].ref
    IN
    \* download_service.py:645-655,342-356,958-989: control-flow guards / captured local decisions.
    /\ st.cb[t].pc = "ready"
    /\ arg = CallbackArgs(t)
    \* download_service.py:645-655,342-356,958-989: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t].pc = "running",
          !.objectDoneCalls = IF k = "objectDone" THEN [st.objectDoneCalls EXCEPT ![r] = @ + 1] ELSE st.objectDoneCalls,
          !.doneCalls = IF k = "txDone" THEN @ + 1 ELSE @,
          !.outcomeCbCalls = IF k = "outcome" THEN @ + 1 ELSE @,
          !.releaseAttempts = IF k = "release" THEN [st.releaseAttempts EXCEPT ![r] = @ + 1] ELSE st.releaseAttempts,
          !.effectsAfterReceipt = @ \/ (k \in {"objectDone", "txDone", "outcome", "release"} /\ (st.waiter = "receipt" \/ st.lateWaiter = "receipt"))]

\* cacheable.py:109-120; download_service.py:193-201,988-989: owned-source release drops only the infrastructure reference, before its hook returns
ReleaseSourceReference(t) ==
    \* cacheable.py:109-120; download_service.py:193-201,988-989: control-flow guards / captured local decisions.
    /\ st.cb[t].pc = "running"
    /\ st.cb[t].kind = "release"
    \* cacheable.py:109-120; download_service.py:193-201,988-989: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.sourceHeld[st.cb[t].ref] = FALSE,
          !.cb[t].pc = "releaseReturn"]

\* download_service.py:645-655: finite callback returns; no caller phase advances until this return
CallbackReturn(t) ==
    \* download_service.py:645-655: control-flow guards / captured local decisions.
    /\ st.cb[t].pc = "releaseReturn" \/ (st.cb[t].pc = "running" /\ st.cb[t].kind # "release")
    \* download_service.py:645-655: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t].pc = "done"]

\* download_service.py:645-655,985-989: ordinary callback/release Exception is contained; already visible effects are not undone
CallbackException(t) ==
    \* download_service.py:645-655,985-989: control-flow guards / captured local decisions.
    /\ st.cb[t].pc = "running"
    \* download_service.py:645-655,985-989: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.cb[t].pc = "done",
          !.callbackErrors = @ + 1]

\* download_service.py:988-999: all this invocation's release attempts have returned before on_outcome recording
TransactionDoneRecordReady(t) ==
    \* download_service.py:988-999: control-flow guards / captured local decisions.
    /\ st.spc[t] = "release"
    /\ st.todo[t] = {}
    /\ st.cb[t].pc = "idle"
    \* download_service.py:988-999: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.spc[t] = "record"]

\* download_service.py:1579-1595,998-1000: owner-guarded single receipt write; resolve pending waiters atomically with recording
RecordOutcome(t) ==
    \* download_service.py:1579-1595,998-1000: control-flow guards / captured local decisions.
    /\ st.spc[t] = "record"
    /\ st.owner
    \* download_service.py:1579-1595,998-1000: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.owner = FALSE,
          !.receiptWrites = @ + 1,
          !.receipt = st.verdicts[t],
          !.retained = TRUE,
          !.recordAt = st.now,
          !.recordedBy = t,
          !.waiter = IF @ = "pending" THEN "receipt" ELSE @,
          !.waiterOutcome = IF st.waiter = "pending" THEN st.verdicts[t] ELSE @,
          !.lateWaiter = IF @ = "pending" THEN "receipt" ELSE @,
          !.lateOutcome = IF st.lateWaiter = "pending" THEN st.verdicts[t] ELSE @,
          !.spc[t] = "complete"]

\* download_service.py:1582-1585,998-1000: ownership consumed by another record or cleared by shutdown: discard duplicate receipt
RecordOutcomeDrop(t) ==
    \* download_service.py:1582-1585,998-1000: control-flow guards / captured local decisions.
    /\ st.spc[t] = "record"
    /\ ~st.owner
    \* download_service.py:1582-1585,998-1000: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.spc[t] = "complete"]

\* download_service.py:1000-1002: set settlement_complete after recording returns; this is not an entry latch
TransactionDoneComplete(t) ==
    \* download_service.py:1000-1002: control-flow guards / captured local decisions.
    /\ st.spc[t] = "complete"
    \* download_service.py:1000-1002: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.settlementComplete = TRUE,
          !.spc[t] = "markerRead"]

\* download_service.py:1500-1505: snapshot whether admitted operations remain under operation lock
SyncTerminationMarkerRead(t) ==
    \* download_service.py:1500-1505: control-flow guards / captured local decisions.
    /\ st.spc[t] = "markerRead"
    \* download_service.py:1500-1505: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.markerLeaked[t] = st.ops # {},
          !.spc[t] = "markerWrite"]

\* download_service.py:1506-1510: sustain or clear marker under table lock using sampled operation state
SyncTerminationMarkerWrite(t) ==
    \* download_service.py:1506-1510: control-flow guards / captured local decisions.
    /\ st.spc[t] = "markerWrite"
    \* download_service.py:1506-1510: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.terminating = st.markerLeaked[t] \/ ~st.settlementComplete,
          !.spc[t] = "done"]

\* download_service.py:1513-1522: monitor removes a quiescent marker; remaining settlement duplication is not counted by this latch
ReapTerminationMarker ==
    \* download_service.py:1513-1522: control-flow guards / captured local decisions.
    /\ st.terminating
    /\ st.settlementComplete
    /\ st.ops = {}
    \* download_service.py:1513-1522: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.terminating = FALSE]

\* download_service.py:1611-1619; transfer_outcome.py:181-182: remove retained receipt after strict greater-than TTL; previously resolved waiters retain their value
ExpireOutcome ==
    \* download_service.py:1611-1619; transfer_outcome.py:181-182: control-flow guards / captured local decisions.
    /\ st.retained
    /\ st.now - st.recordAt > ReceiptTTL
    \* download_service.py:1611-1619; transfer_outcome.py:181-182: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.retained = FALSE]

\* download_service.py:1544-1565: attach a second observer; unswept expired receipt still resolves it, exactly as current API
GetTransferWaiter ==
    \* download_service.py:1544-1565: control-flow guards / captured local decisions.
    /\ st.lateWaiter = "unregistered"
    \* download_service.py:1544-1565: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.lateWaiter = IF st.retained THEN "receipt" ELSE IF st.owner THEN "pending" ELSE "none",
          !.lateOutcome = IF st.retained THEN st.receipt ELSE EmptyVerdict]

\* nvflare/client/cell/api.py:624-648: minimal caller barrier: only a non-None strict COMPLETED receipt permits success
WaitForResultTransfers ==
    \* nvflare/client/cell/api.py:624-648: control-flow guards / captured local decisions.
    /\ st.caller = "waiting"
    /\ st.waiter # "pending"
    \* nvflare/client/cell/api.py:624-648: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.caller = IF st.waiter = "receipt" /\ st.waiterOutcome.status = "completed" THEN "success" ELSE "error"]

\* download_service.py:441-442,774-775,843-849,1850,1909: advance abstract monotone wall time; monitor execution remains independent
AdvanceTime ==
    \* download_service.py:441-442,774-775,843-849,1850,1909: control-flow guards / captured local decisions.
    /\ TRUE
    \* download_service.py:441-442,774-775,843-849,1850,1909: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.now = @ + 1]

\* download_service.py:1716,1724-1732: produce returns ERROR as an ordinary functional outcome, provisionally awaiting receiver truth
HandleDownloadProduceError(p) ==
    \* download_service.py:1716,1724-1732: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "produce"
    /\ st.pub[Pull(p)].pc = "idle"
    \* download_service.py:1716,1724-1732: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.rc[p] = "error",
          !.pullPC[p] = "served"]

\* download_service.py:2260-2265,2285-2289: terminal ERROR carries nonce; prepare FAILED confirmation without download_completed
ConsumerReceiveProducerError(p) ==
    \* download_service.py:2260-2265,2285-2289: control-flow guards / captured local decisions.
    /\ st.consumer[p] = "waiting"
    /\ st.reply[p] = "error"
    \* download_service.py:2260-2265,2285-2289: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.reply[p] = "none",
          !.consumerNonce[p] = st.replyNonce[p],
          !.consumerResult[p] = "failed",
          !.consumer[p] = "confirmReady"]

\* download_service.py:2166-2182,2300-2305,2312-2313: the submitted pipeline future starts before remote admission; cancel can no longer erase the request
DownloadRequestWorkerStart(p) ==
    \* download_service.py:2166-2182,2300-2305,2312-2313: control-flow guards / captured local decisions.
    /\ st.pullPC[p] = "sent"
    /\ ~st.futureStarted[p]
    \* download_service.py:2166-2182,2300-2305,2312-2313: updates; EXCEPT frames every unlisted state field.
    /\ st' = [st EXCEPT
          !.futureStarted[p] = TRUE]


\* Structural types follow the concrete records and the abstraction domains above.
EventType == [pair : Pairs \cup {NullPair}, state : ProgressStates, seq : Nat, bytes : Nat]
PubType == [pc : {"idle","make","call","return"}, pair : Pairs \cup {NullPair},
            want : ProgressStates, delta : Nat, force : BOOLEAN,
            events : SUBSET EventType, current : EventType]
CBType == [pc : {"idle","ready","running","releaseReturn","done"},
           kind : {"none","one","all","objectDone","txDone","outcome","release"},
           ref : Refs \cup {"-"}]
VerdictType == [status : TerminalStates \cup {"none"},
               reason : {"none","all_receivers_succeeded","deleted","timeout","receiver_failed","computation_failed"},
               done : {"none","finished","timeout","deleted"},
               matrix : [Pairs -> FinalStatuses], refsPresent : BOOLEAN, quorum : BOOLEAN]
TypeOK ==
    /\ DOMAIN st = {"abandoned", "acquired", "allDone", "baseObjects", "budgetLast", "budgetNow", "callbackErrors", "caller", "cancelWire", "cause", "cb", "closed", "confirmWire", "consumer", "consumerNonce", "consumerResult", "doneCalls", "drainAt", "drainForced", "effectsAfterReceipt", "faccepted", "fall", "finishReady", "fp", "fpc", "ftodo", "futureStarted", "fwon", "index", "lateOutcome", "lateWaiter", "live", "markerLeaked", "monitorNow", "monitorPC", "nonce", "now", "objectDoneCalls", "observedTerminal", "ops", "outcomeCbCalls", "owner", "pending", "progressBytes", "progressOrder", "progressSeq", "progressStarted", "progressTerminal", "provisional", "pub", "pullPC", "pullTime", "queued", "rc", "receipt", "receiptWrites", "receiverLast", "recordAt", "recordedBy", "refLast", "refTerminal", "releaseAttempts", "reply", "replyNonce", "retained", "settlementComplete", "shutdown", "snapshots", "sourceHeld", "spc", "status", "submitPC", "terminating", "todo", "tombstoneAt", "txLast", "verdicts", "waiter", "waiterOutcome"}
    /\ st.abandoned \in SUBSET Receivers
    /\ st.acquired \in SUBSET Receivers
    /\ st.allDone \in [Refs -> BOOLEAN]
    /\ st.baseObjects \in [Settlers -> [Refs -> BOOLEAN]]
    /\ st.budgetLast \in [Receivers -> Int]
    /\ st.budgetNow \in Nat
    /\ st.callbackErrors \in Nat
    /\ st.caller \in {"waiting","success","error"}
    /\ st.cancelWire \in SUBSET Receivers
    /\ st.cause \in {"none","finished","timeout","deleted"}
    /\ st.cb \in [Actors -> CBType]
    /\ st.closed \in BOOLEAN
    /\ st.confirmWire \in SUBSET Pairs
    /\ st.consumer \in [Pairs -> {"new","waiting","data","consuming","completing","confirmReady","done","failed"}]
    /\ st.consumerNonce \in [Pairs -> BOOLEAN]
    /\ st.consumerResult \in [Pairs -> FinalStatuses]
    /\ st.doneCalls \in Nat
    /\ st.drainAt \in [Settlers -> Nat]
    /\ st.drainForced \in [Settlers -> BOOLEAN]
    /\ st.effectsAfterReceipt \in BOOLEAN
    /\ st.faccepted \in [Finalizers -> BOOLEAN]
    /\ st.fall \in [Finalizers -> BOOLEAN]
    /\ st.finishReady \in SUBSET (Confirmers \cup Cancellers)
    /\ st.fp \in [Finalizers -> (Pairs \cup {NullPair})]
    /\ st.fpc \in [Finalizers -> {"idle","acquired","select","commit","one","all","progress","advance","end","done","snapshot","recheck"}]
    /\ st.ftodo \in [Finalizers -> SUBSET Pairs]
    /\ st.futureStarted \in [Pairs -> BOOLEAN]
    /\ st.fwon \in [Finalizers -> BOOLEAN]
    /\ st.index \in [Pairs -> Nat]
    /\ st.lateOutcome \in VerdictType
    /\ st.lateWaiter \in {"unregistered","pending","receipt","none"}
    /\ st.live \in BOOLEAN
    /\ st.markerLeaked \in [Settlers -> BOOLEAN]
    /\ st.monitorNow \in Nat
    /\ st.monitorPC \in {"idle","admit","budget","classify","settling"}
    /\ st.nonce \in [Pairs -> BOOLEAN]
    /\ st.now \in Nat
    /\ st.objectDoneCalls \in [Refs -> Nat]
    /\ st.observedTerminal \in [Pairs -> (TerminalStates \cup {"none"})]
    /\ st.ops \in SUBSET (Pullers \cup Finalizers)
    /\ st.outcomeCbCalls \in Nat
    /\ st.owner \in BOOLEAN
    /\ st.pending \in [Pairs -> BOOLEAN]
    /\ st.progressBytes \in [Pairs -> Nat]
    /\ st.progressOrder \in [Refs -> Seq(Receivers)]
    /\ st.progressSeq \in [Pairs -> Nat]
    /\ st.progressStarted \in SUBSET Pairs
    /\ st.progressTerminal \in [Pairs -> (TerminalStates \cup {"none"})]
    /\ st.provisional \in [Pairs -> FinalStatuses]
    /\ st.pub \in [Actors -> PubType]
    /\ st.pullPC \in [Pairs -> {"idle","sent","markTx","markRef","markReceiver","startProgress","produce","dataProgress","served","terminalProgress","end","done"}]
    /\ st.pullTime \in [Pairs -> Nat]
    /\ st.queued \in BOOLEAN
    /\ st.rc \in [Pairs -> {"none","data","eof","error","exception","missing"}]
    /\ st.receipt \in VerdictType
    /\ st.receiptWrites \in Nat
    /\ st.receiverLast \in [Receivers -> Int]
    /\ st.recordAt \in Nat
    /\ st.recordedBy \in Settlers
    /\ st.refLast \in [Pairs -> Int]
    /\ st.refTerminal \in [Refs -> (TerminalStates \cup {"none"})]
    /\ st.releaseAttempts \in [Refs -> Nat]
    /\ st.reply \in [Pairs -> {"none","data","eof","error","exception","missing"}]
    /\ st.replyNonce \in [Pairs -> BOOLEAN]
    /\ st.retained \in BOOLEAN
    /\ st.settlementComplete \in BOOLEAN
    /\ st.shutdown \in BOOLEAN
    /\ st.snapshots \in [Settlers -> [Pairs -> FinalStatuses]]
    /\ st.sourceHeld \in [Refs -> BOOLEAN]
    /\ st.spc \in [Settlers -> {"idle","enter","drain","snapshot","terminalProgress","baseObjects","objects","txCallback","outcomeCallback","release","record","complete","markerRead","markerWrite","done"}]
    /\ st.status \in [Pairs -> FinalStatuses]
    /\ st.submitPC \in {"idle","ready","enqueued","fallback","done"}
    /\ st.terminating \in BOOLEAN
    /\ st.todo \in [Settlers -> SUBSET Refs]
    /\ st.tombstoneAt \in Int
    /\ st.txLast \in Nat
    /\ st.verdicts \in [Settlers -> VerdictType]
    /\ st.waiter \in {"pending","receipt","none"}
    /\ st.waiterOutcome \in VerdictType

\* download_service.py:313-335,392-396: final status cannot coexist with pending.
FinalStatusStructure == \A p \in Pairs :
    /\ (st.status[p] # "none" => ~st.pending[p])
    /\ (st.pending[p] = (st.provisional[p] # "none"))
AllDoneStructure == \A r \in Refs : st.allDone[r] = RefFinished(st.status, r)
\* download_service.py:1582-1595: receipt ownership guards publication, not entry.
SingleReceipt == st.receiptWrites <= 1 /\ (st.receiptWrites = 1 => ~st.owner)
\* download_service.py:2273-2283,399-423: served terminal data alone cannot certify.
ConfirmedSuccess == \A p \in Pairs : st.status[p] = "success" => st.consumerResult[p] = "success"
\* transfer_outcome.py:156-202,242-259: test frozen outcome matrix, not later state.
OutcomeAggregation ==
    \A v \in {st.receipt, st.waiterOutcome, st.lateOutcome} \cup {st.verdicts[t] : t \in Settlers} :
       /\ (v.status = "completed" => v.refsPresent /\ AllSucceeded(v.matrix))
       /\ (v.quorum => v.refsPresent /\ Cardinality(CommonSuccess(v.matrix)) >= MinReceivers)
\* download_service.py:895-1000: successful recording invocation has finished all
\* its hooks and release attempts, even when another invocation is still running.
ReceiptFollowsOwnCleanup ==
    st.receiptWrites = 1 =>
       /\ st.spc[st.recordedBy] \in {"complete","markerRead","markerWrite","done"}
       /\ st.doneCalls >= 1 /\ st.outcomeCbCalls >= 1
       /\ \A r \in Refs : st.objectDoneCalls[r] >= 1 /\ st.releaseAttempts[r] >= 1
\* nvflare/client/cell/api.py:624-648: strict caller observer.
CallerRequiresCompleted == st.caller = "success" => st.waiterOutcome.status = "completed"
\* Structural timing/ownership assertions do not forbid policy-approved forced drain.
ClosedAfterRetirement == st.closed => ~st.live
\* Brief section 5 / S3,S5: the open settlement effects questions.
SingleSettlementEffects ==
    /\ st.doneCalls <= 1 /\ st.outcomeCbCalls <= 1
    /\ \A r \in Refs : st.objectDoneCalls[r] <= 1 /\ st.releaseAttempts[r] <= 1
NoSettlementEffectsAfterReceipt == ~st.effectsAfterReceipt
\* Brief section 5 / S1: public callback delivery, not a trainer success claim.
CompletedProgressHasReceiverSuccess ==
    \A p \in Pairs : st.observedTerminal[p] = "completed" => st.status[p] = "success"
\* Immutability is a transition property; it does not constrain Next.
FinalStatusesImmutable == [] [\A p \in Pairs : st.status[p] # "none" => st'.status[p] = st.status[p]]_vars

ReactiveNext ==
    \/ \E p \in Pairs : (DownloadObjectStart(p))
    \/ \E p \in Pairs : (HandleDownloadBegin(p))
    \/ \E p \in Pairs : (HandleDownloadMissing(p))
    \/ \E p \in Pairs : (HandleDownloadMarkActive(p))
    \/ \E p \in Pairs : (RefMarkReceiverActive(p))
    \/ \E p \in Pairs : (TransactionMarkReceiverActive(p))
    \/ \E p \in Pairs : (HandleDownloadActiveProgress(p))
    \/ \E p \in Pairs : (HandleDownloadProduce(p))
    \/ \E p \in Pairs : (RefObjServed(p))
    \/ \E p \in Pairs : (HandleDownloadTerminalProgress(p))
    \/ \E p \in Pairs : (HandleDownloadDataProgress(p))
    \/ \E p \in Pairs : (HandleDownloadEndOp(p))
    \/ \E p \in Pairs : (ConsumerReceiveData(p))
    \/ \E p \in Pairs : (ConsumerLaunchPipeline(p))
    \/ \E p \in Pairs : (ConsumerConsumeReturn(p))
    \/ \E p \in Pairs : (ConsumerReceiveEOF(p))
    \/ \E p \in Pairs : (ConsumerDownloadCompleted(p))
    \/ \E p \in Pairs : (ConsumerSendConfirm(p))
    \/ \E p \in Pairs : (ConsumerReceiveError(p))
    \/ \E p \in Pairs : (HandleConfirmBegin(p))
    \/ \E p \in Pairs : (HandleConfirmLate(p))
    \/ \E c \in Receivers : (HandleCancelBegin(c))
    \/ \E c \in Receivers : (HandleCancelLate(c))
    \/ \E c \in Receivers : (HandleCancelAcquired(c))
    \/ \E t \in Confirmers \cup Cancellers : (\E p \in Pairs : (FinalizerSelectRef(t, p)))
    \/ \E t \in Finalizers : (RefFinalizeReceiverCommit(t))
    \/ \E t \in Finalizers : (RefDownloadedToOneReturned(t))
    \/ \E t \in Finalizers : (RefDownloadedToAllReturned(t))
    \/ \E t \in Finalizers : (RefFinalizerProgress(t))
    \/ \E t \in Finalizers : (FinalizerAdvance(t))
    \/ \E p \in Pairs : (HandleConfirmMarkActive(p))
    \/ \E c \in Receivers : (HandleCancelLoopDone(c))
    \/ \E t \in Confirmers \cup Cancellers : (FinalizerEndOp(t))
    \/ MonitorBegin
    \/ MonitorAdmitBudgets
    \/ EnforceReceiverBudgetsSnapshot
    \/ \E p \in Pairs : (RefEnforceBudgetSelect(p))
    \/ RefEnforceBudgetRecheck
    \/ MonitorBudgetEndOp
    \/ MonitorNoRetirement
    \/ \E t \in Confirmers \cup Cancellers : (FinishTransactionIfComplete(t))
    \/ \E t \in Confirmers \cup Cancellers : (FinishTransactionNotComplete(t))
    \/ MonitorRetireFinished
    \/ MonitorRetireTimeout
    \/ \E t \in Actors : (RefMakeProgressEvent(t))
    \/ \E t \in Actors : (\E e \in st.pub[t].events : (TransactionEmitProgressEvent(t, e)))
    \/ \E t \in Actors : (TransactionProgressCallbackReturn(t))
    \/ CheckedExecutorEnqueue
    \/ CheckedExecutorSubmitReturn
    \/ SubmitFinishedSettlementFallback
    \/ SettleFinishedTransactionWorker
    \/ \E t \in Settlers : (TransactionDoneDrainBegin(t))
    \/ \E t \in Settlers : (TransactionDoneDrainEmpty(t))
    \/ \E t \in Settlers : (TransactionDoneDrainExpired(t))
    \/ \E t \in Settlers : (\E r \in Refs : (TransactionDoneSnapshotRef(t, r)))
    \/ \E t \in Settlers : (TransactionDoneComputeOutcome(t))
    \/ \E t \in Settlers : (\E r \in Refs : (TransactionDoneTerminalProgress(t, r)))
    \/ \E t \in Settlers : (TransactionDoneProgressReturned(t))
    \/ \E t \in Settlers : (\E r \in Refs : (TransactionDoneSnapshotBaseObject(t, r)))
    \/ \E t \in Settlers : (TransactionDoneObjectsBegin(t))
    \/ \E t \in Settlers : (\E r \in Refs : (TransactionDoneObjectCallback(t, r)))
    \/ \E t \in Settlers : (TransactionDoneObjectReturned(t))
    \/ \E t \in Settlers : (TransactionDoneTransactionCallback(t))
    \/ \E t \in Settlers : (TransactionDoneOutcomeCallback(t))
    \/ \E t \in Settlers : (TransactionDoneReleaseBegin(t))
    \/ \E t \in Settlers : (\E r \in Refs : (TransactionDoneRelease(t, r)))
    \/ \E t \in Settlers : (TransactionDoneReleaseReturned(t))
    \/ \E t \in Actors : (\E arg \in {CallbackArgs(t)} : (InvokeCallbackSafely(t, arg)))
    \/ \E t \in Settlers : (ReleaseSourceReference(t))
    \/ \E t \in Actors : (CallbackReturn(t))
    \/ \E t \in Settlers : (TransactionDoneRecordReady(t))
    \/ \E t \in Settlers : (RecordOutcome(t))
    \/ \E t \in Settlers : (RecordOutcomeDrop(t))
    \/ \E t \in Settlers : (TransactionDoneComplete(t))
    \/ \E t \in Settlers : (SyncTerminationMarkerRead(t))
    \/ \E t \in Settlers : (SyncTerminationMarkerWrite(t))
    \/ ReapTerminationMarker
    \/ ExpireOutcome
    \/ GetTransferWaiter
    \/ WaitForResultTransfers
    \/ \E p \in Pairs : (ConsumerReceiveProducerError(p))
    \/ \E p \in Pairs : (DownloadRequestWorkerStart(p))

FaultNext ==
    \/ \E p \in Pairs : (HandleDownloadProduceException(p))
    \/ \E p \in Pairs : (ConsumerConsumeException(p))
    \/ \E p \in Pairs : (ConsumerDownloadCompletedException(p))
    \/ \E p \in Pairs : (LoseConfirmation(p))
    \/ DeleteTransaction
    \/ Shutdown
    \/ CheckedExecutorSubmitRuntimeError
    \/ CheckedExecutorSubmitStopped
    \/ \E t \in Settlers : (TransactionDoneComputeException(t))
    \/ \E t \in Actors : (CallbackException(t))
    \/ AdvanceTime
    \/ \E p \in Pairs : (HandleDownloadProduceError(p))

Next == ReactiveNext \/ FaultNext
Spec == Init /\ [][Next]_vars
\* Conditional scheduling contract: fair enabled action instances (including
\* callback return and queued-worker execution) and advancing time. No finite
\* real-world wall-clock promise or fairness for loss/exception injections.
SettlementFairness ==
    /\ WF_vars(AdvanceTime)
    /\ \A p \in Pairs : (WF_vars(DownloadObjectStart(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadBegin(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadMissing(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadMarkActive(p)))
    /\ \A p \in Pairs : (WF_vars(RefMarkReceiverActive(p)))
    /\ \A p \in Pairs : (WF_vars(TransactionMarkReceiverActive(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadActiveProgress(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadProduce(p)))
    /\ \A p \in Pairs : (WF_vars(RefObjServed(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadTerminalProgress(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadDataProgress(p)))
    /\ \A p \in Pairs : (WF_vars(HandleDownloadEndOp(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerReceiveData(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerLaunchPipeline(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerConsumeReturn(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerReceiveEOF(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerDownloadCompleted(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerSendConfirm(p)))
    /\ \A p \in Pairs : (WF_vars(ConsumerReceiveError(p)))
    /\ \A p \in Pairs : (WF_vars(HandleConfirmBegin(p)))
    /\ \A p \in Pairs : (WF_vars(HandleConfirmLate(p)))
    /\ \A c \in Receivers : (WF_vars(HandleCancelBegin(c)))
    /\ \A c \in Receivers : (WF_vars(HandleCancelLate(c)))
    /\ \A c \in Receivers : (WF_vars(HandleCancelAcquired(c)))
    /\ \A t \in Confirmers \cup Cancellers : (\A p \in Pairs : (WF_vars(FinalizerSelectRef(t, p))))
    /\ \A t \in Finalizers : (WF_vars(RefFinalizeReceiverCommit(t)))
    /\ \A t \in Finalizers : (WF_vars(RefDownloadedToOneReturned(t)))
    /\ \A t \in Finalizers : (WF_vars(RefDownloadedToAllReturned(t)))
    /\ \A t \in Finalizers : (WF_vars(RefFinalizerProgress(t)))
    /\ \A t \in Finalizers : (WF_vars(FinalizerAdvance(t)))
    /\ \A p \in Pairs : (WF_vars(HandleConfirmMarkActive(p)))
    /\ \A c \in Receivers : (WF_vars(HandleCancelLoopDone(c)))
    /\ \A t \in Confirmers \cup Cancellers : (WF_vars(FinalizerEndOp(t)))
    /\ WF_vars(MonitorBegin)
    /\ WF_vars(MonitorAdmitBudgets)
    /\ WF_vars(EnforceReceiverBudgetsSnapshot)
    /\ \A p \in Pairs : (WF_vars(RefEnforceBudgetSelect(p)))
    /\ WF_vars(RefEnforceBudgetRecheck)
    /\ WF_vars(MonitorBudgetEndOp)
    /\ WF_vars(MonitorNoRetirement)
    /\ \A t \in Confirmers \cup Cancellers : (WF_vars(FinishTransactionIfComplete(t)))
    /\ \A t \in Confirmers \cup Cancellers : (WF_vars(FinishTransactionNotComplete(t)))
    /\ WF_vars(MonitorRetireFinished)
    /\ WF_vars(MonitorRetireTimeout)
    /\ \A t \in Actors : (WF_vars(RefMakeProgressEvent(t)))
    /\ \A t \in Actors : (WF_vars(\E e \in st.pub[t].events : (TransactionEmitProgressEvent(t, e))))
    /\ \A t \in Actors : (WF_vars(TransactionProgressCallbackReturn(t)))
    /\ WF_vars(CheckedExecutorEnqueue)
    /\ WF_vars(CheckedExecutorSubmitReturn)
    /\ WF_vars(SubmitFinishedSettlementFallback)
    /\ WF_vars(SettleFinishedTransactionWorker)
    /\ \A t \in Settlers : (WF_vars(TransactionDoneDrainBegin(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneDrainEmpty(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneDrainExpired(t)))
    /\ \A t \in Settlers : (\A r \in Refs : (WF_vars(TransactionDoneSnapshotRef(t, r))))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneComputeOutcome(t)))
    /\ \A t \in Settlers : (\A r \in Refs : (WF_vars(TransactionDoneTerminalProgress(t, r))))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneProgressReturned(t)))
    /\ \A t \in Settlers : (\A r \in Refs : (WF_vars(TransactionDoneSnapshotBaseObject(t, r))))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneObjectsBegin(t)))
    /\ \A t \in Settlers : (\A r \in Refs : (WF_vars(TransactionDoneObjectCallback(t, r))))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneObjectReturned(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneTransactionCallback(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneOutcomeCallback(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneReleaseBegin(t)))
    /\ \A t \in Settlers : (\A r \in Refs : (WF_vars(TransactionDoneRelease(t, r))))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneReleaseReturned(t)))
    /\ \A t \in Actors : (WF_vars(\E arg \in {CallbackArgs(t)} : (InvokeCallbackSafely(t, arg))))
    /\ \A t \in Settlers : (WF_vars(ReleaseSourceReference(t)))
    /\ \A t \in Actors : (WF_vars(CallbackReturn(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneRecordReady(t)))
    /\ \A t \in Settlers : (WF_vars(RecordOutcome(t)))
    /\ \A t \in Settlers : (WF_vars(RecordOutcomeDrop(t)))
    /\ \A t \in Settlers : (WF_vars(TransactionDoneComplete(t)))
    /\ \A t \in Settlers : (WF_vars(SyncTerminationMarkerRead(t)))
    /\ \A t \in Settlers : (WF_vars(SyncTerminationMarkerWrite(t)))
    /\ WF_vars(ReapTerminationMarker)
    /\ WF_vars(ExpireOutcome)
    /\ WF_vars(GetTransferWaiter)
    /\ WF_vars(WaitForResultTransfers)
    /\ \A p \in Pairs : (WF_vars(ConsumerReceiveProducerError(p)))
    /\ \A p \in Pairs : (WF_vars(DownloadRequestWorkerStart(p)))

FairSpec == Spec /\ SettlementFairness
EventualSettlementObservation == (<>~st.live) => <>(st.waiter # "pending")
=============================================================================
