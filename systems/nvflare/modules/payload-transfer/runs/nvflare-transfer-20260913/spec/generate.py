from pathlib import Path
import json
P = Path(__file__).resolve().parent
A = []
def action(name, params, source, trigger, guards, updates, lets='', fault=None):
    if name in {'TransactionDoneSnapshotRef','TransactionDoneTerminalProgress','TransactionDoneSnapshotBaseObject','TransactionDoneObjectCallback','TransactionDoneRelease'}:
        guards = guards + ['r = FirstRef(st.todo[t])']
    if name == 'FinalizerSelectRef':
        guards = guards + [r'p[1] = FirstRef({q[1] : q \in st.ftodo[t]})']
    if name == 'RefEnforceBudgetSelect':
        guards = guards + [r'p[1] = FirstRef({q[1] : q \in st.ftodo[Budget]})']
    if name in {'HandleDownloadBegin','HandleDownloadMissing'}:
        guards = guards + ['st.futureStarted[p]']
    if name in {'FinishTransactionIfComplete','MonitorRetireFinished'}:
        updates = updates + [('tombstoneAt','st.now')]
    if name == 'InvokeCallbackSafely':
        guards = guards + ['arg = CallbackArgs(t)']
    if name == 'TransactionEmitProgressEvent':
        guards = guards + ['e = FirstProgressEvent(st.pub[t].events)']
    fields = sorted({k.split('[')[0].split('.')[0] for k,v in updates})
    A.append(dict(name=name, params=params, source=source, trigger=trigger, fields=fields, fault=fault))
    sig = name + ('(' + ', '.join(n for n,d in params) + ')' if params else '')
    body = '\\* ' + source + ': ' + trigger + '\n' + sig + ' ==\n'
    if lets:
        body += '    LET ' + lets.replace('\n', '\n        ') + '\n    IN\n'
    body += '    \\* ' + source + ': control-flow guards / captured local decisions.\n'
    body += '\n'.join('    /\\ ' + g for g in guards) + '\n'
    body += '    \\* ' + source + ': updates; EXCEPT frames every unlisted state field.\n'
    body += "    /\\ st' = [st EXCEPT\n" + ',\n'.join('          !.'+k+' = '+v for k,v in updates) + ']\n\n'
    return body
header = r'''------------------------------- MODULE base -------------------------------
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
          recordAt |-> 0, waiter |-> "pending", waiterOutcome |-> EmptyVerdict,
          lateWaiter |-> "unregistered", lateOutcome |-> EmptyVerdict,
          caller |-> "waiting"]

'''
parts = [header]
def add(*args, **kwargs): parts.append(action(*args, **kwargs))
D='download_service.py:'
add('DownloadObjectStart',[('p','Pairs')],D+'2164-2182,2203-2209','send the initial ordinary pull',
    ['st.consumer[p] = "new"','p[2] \\notin st.abandoned'],
    [('consumer[p]','"waiting"'),('futureStarted[p]','TRUE'),('pullPC[p]','"sent"')])
add('HandleDownloadBegin',[('p','Pairs')],D+'1681-1699,822-833','admit a pull while holding the table and operation locks',
    ['st.pullPC[p] = "sent"','st.live','~st.closed'],
    [('ops','@ \\cup {Pull(p)}'),('pullPC[p]','"markTx"')])
add('HandleDownloadMissing',[('p','Pairs')],D+'1681-1697','after ref retirement, return retained finished status or missing-ref error; includes a late first acquisition',
    ['st.pullPC[p] = "sent"','~st.live \\/ st.closed'],
    [('pullPC[p]','"done"'),('reply[p]','IF ~st.shutdown /\\ st.tombstoneAt >= 0 /\\ st.now - st.tombstoneAt <= FinishedRefsTTL THEN (IF st.status[p] = "success" THEN "eof" ELSE "error") ELSE "missing"'),('replyNonce[p]','FALSE')])
add('HandleDownloadMarkActive',[('p','Pairs')],D+'1701,300-301,774-775','update the sliding global inactivity clock',
    ['st.pullPC[p] = "markTx"'], [('txLast','st.now'),('pullPC[p]','"markRef"')])
add('RefMarkReceiverActive',[('p','Pairs')],D+'441-444,1702','capture request time and publish ref activity under progress lock',
    ['st.pullPC[p] = "markRef"'], [('pullTime[p]','st.now'),('refLast[p]','st.now'),('pullPC[p]','"markReceiver"')])
add('TransactionMarkReceiverActive',[('p','Pairs')],D+'445-450','publish the same captured time under transaction stats lock',
    ['st.pullPC[p] = "markReceiver"'], [('receiverLast[p[2]]','st.pullTime[p]'),('acquired','@ \\cup {p[2]}'),('pullPC[p]','"startProgress"')])
add('HandleDownloadActiveProgress',[('p','Pairs')],D+'1703,517-542','request ACTIVE progress before produce',
    ['st.pullPC[p] = "startProgress"','st.pub[Pull(p)].pc = "idle"'],
    [('pub[Pull(p)]','RequestPub(p, "active", 0, FALSE)'),('pullPC[p]','"produce"')])
add('HandleDownloadProduce',[('p','Pairs')],D+'1707-1716,1724,1751-1775','ordinary produce returns DATA then EOF; transport contents abstracted',
    ['st.pullPC[p] = "produce"','st.pub[Pull(p)].pc = "idle"'],
    [('rc[p]','IF st.index[p] < ChunkCount THEN "data" ELSE "eof"'),('pullPC[p]','IF st.index[p] < ChunkCount THEN "dataProgress" ELSE "served"')])
add('HandleDownloadProduceException',[('p','Pairs')],D+'1715-1722','ordinary produce exception prepares FAILED progress and PROCESS_EXCEPTION',
    ['st.pullPC[p] = "produce"','st.pub[Pull(p)].pc = "idle"'],
    [('rc[p]','"exception"'),('pub[Pull(p)]','RequestPub(p, "failed", 0, TRUE)'),('pullPC[p]','"end"')],fault='produce')
add('RefObjServed',[('p','Pairs')],D+'369-397,1728-1732','record a provisional serve or return no nonce when already final',
    ['st.pullPC[p] = "served"'],
    [('provisional[p]','IF st.status[p] = "none" THEN (IF st.rc[p] = "eof" THEN "success" ELSE "failed") ELSE "none"'),('pending[p]','st.status[p] = "none"'),('nonce[p]','st.status[p] = "none"'),('pullPC[p]','"terminalProgress"')])
add('HandleDownloadTerminalProgress',[('p','Pairs')],D+'1733-1749','choose progress from returned serve nonce and producer RC, outside progress lock',
    ['st.pullPC[p] = "terminalProgress"','st.pub[Pull(p)].pc = "idle"'],
    [('pub[Pull(p)]','RequestPub(p, IF st.nonce[p] THEN "active" ELSE IF st.rc[p] = "eof" THEN "completed" ELSE "failed", 0, TRUE)'),('pullPC[p]','"end"')])
add('HandleDownloadDataProgress',[('p','Pairs')],D+'1752-1775','count one abstract data unit and prepare ACTIVE progress',
    ['st.pullPC[p] = "dataProgress"','st.pub[Pull(p)].pc = "idle"'],
    [('pub[Pull(p)]','RequestPub(p, "active", 1, FALSE)'),('nonce[p]','FALSE'),('pullPC[p]','"end"')])
add('HandleDownloadEndOp',[('p','Pairs')],D+'1750,1768-1779,835-839','finally leaves the operation gate before the reply becomes receivable',
    ['st.pullPC[p] = "end"','st.pub[Pull(p)].pc = "idle"'],
    [('ops','@ \\ {Pull(p)}'),('pullPC[p]','"done"'),('reply[p]','st.rc[p]'),('replyNonce[p]','st.nonce[p]')])
add('ConsumerReceiveData',[('p','Pairs')],D+'2212-2213,2291-2298','receive DATA and remember cancel capability; one unit consumed next',
    ['st.consumer[p] = "waiting"','st.reply[p] = "data"'],
    [('reply[p]','"none"'),('consumer[p]','"data"'),('index[p]','@ + 1')])
add('ConsumerLaunchPipeline',[('p','Pairs')],D+'2300-2305','submit next request BEFORE calling consume on the current data',
    ['st.consumer[p] = "data"','st.pullPC[p] = "done"'],
    [('consumer[p]','"consuming"'),('futureStarted[p]','FALSE'),('pullPC[p]','"sent"')])
add('ConsumerConsumeReturn',[('p','Pairs')],D+'2309-2310,2333-2349','value-stable consume returns; wait for the already submitted request',
    ['st.consumer[p] = "consuming"'], [('consumer[p]','"waiting"')])
add('ConsumerConsumeException',[('p','Pairs')],D+'2311-2317','consume raises; cancel an unstarted future, but an admitted request keeps running',
    ['st.consumer[p] = "consuming"'],
    [('consumer[p]','"failed"'),('consumerResult[p]','"failed"'),('abandoned','@ \\cup {p[2]}'),
     ('cancelWire','@ \\cup {p[2]}'),('pullPC[p]','IF ~st.futureStarted[p] THEN "done" ELSE @')],fault='consumer')
add('ConsumerReceiveEOF',[('p','Pairs')],D+'2260-2274','receive EOF and enter download_completed before sending any confirmation',
    ['st.consumer[p] = "waiting"','st.reply[p] = "eof"'],
    [('reply[p]','"none"'),('consumerNonce[p]','st.replyNonce[p]'),('consumer[p]','"completing"')])
add('ConsumerDownloadCompleted',[('p','Pairs')],D+'2273-2283','download_completed returns successfully',
    ['st.consumer[p] = "completing"'],[('consumerResult[p]','"success"'),('consumer[p]','"confirmReady"')])
add('ConsumerDownloadCompletedException',[('p','Pairs')],D+'2273-2281','download_completed raises and schedules FAILED confirmation',
    ['st.consumer[p] = "completing"'],[('consumerResult[p]','"failed"'),('consumer[p]','"confirmReady"')],fault='consumer')
add('ConsumerSendConfirm',[('p','Pairs')],D+'2083-2105,2279-2283','send receiver truth only if terminal reply requested nonce-bound confirmation',
    ['st.consumer[p] = "confirmReady"'],
    [('confirmWire','IF st.consumerNonce[p] THEN @ \\cup {p} ELSE @'),('consumer[p]','"done"')])
add('ConsumerReceiveError',[('p','Pairs')],D+'2221-2250','ordinary failed request causes cancellation after acquisition',
    ['st.consumer[p] = "waiting"','st.reply[p] \\in {"exception", "missing"}'],
    [('reply[p]','"none"'),('consumer[p]','"failed"'),('consumerResult[p]','"failed"'),('abandoned','@ \\cup {p[2]}'),
     ('cancelWire','IF st.index[p] > 0 THEN @ \\cup {p[2]} ELSE @')])
add('LoseConfirmation',[('p','Pairs')],D+'2083-2105,456-469','best-effort confirmation fails to arrive; receiver budgets remain the backstop',
    ['p \\in st.confirmWire'], [('confirmWire','@ \\ {p}')],fault='loss')

# Emit the first phase incrementally while further actions are assembled.
(P/'base.tla').write_text(''.join(parts)+'\\* Generation in progress: finalizers and settlement follow.\n====\n')
add('HandleConfirmBegin',[('p','Pairs')],D+'1782-1799,822-833','admit confirmation, preserving nonce requirement for the later final-status lock',
    ['p \\in st.confirmWire','st.fpc[Confirm(p)] = "idle"','st.live','~st.closed'],
    [('confirmWire','@ \\ {p}'),('ops','@ \\cup {Confirm(p)}'),('ftodo[Confirm(p)]','{p}'),('fpc[Confirm(p)]','"select"')])
add('HandleConfirmLate',[('p','Pairs')],D+'1783-1793','drop confirmation after retirement/closed gate',
    ['p \\in st.confirmWire','~st.live \\/ st.closed'], [('confirmWire','@ \\ {p}')])
add('HandleCancelBegin',[('c','Receivers')],D+'1814-1827,822-833','admit cancellation before testing transaction-level acquisition',
    ['c \\in st.cancelWire','st.fpc[Cancel(c)] = "idle"','st.live','~st.closed'],
    [('cancelWire','@ \\ {c}'),('ops','@ \\cup {Cancel(c)}'),('fpc[Cancel(c)]','"acquired"')])
add('HandleCancelLate',[('c','Receivers')],D+'1816-1822','drop cancellation after retirement/closed gate',
    ['c \\in st.cancelWire','~st.live \\/ st.closed'], [('cancelWire','@ \\ {c}')])
add('HandleCancelAcquired',[('c','Receivers')],D+'1828-1839','snapshot acquired membership, then iterate all fixed sibling refs',
    ['st.fpc[Cancel(c)] = "acquired"'],
    [('ftodo[Cancel(c)]','IF c \\in st.acquired THEN {<<r,c>> : r \\in Refs} ELSE {}'),('fpc[Cancel(c)]','"select"')])
add('FinalizerSelectRef',[('t','Confirmers \\cup Cancellers'),('p','Pairs')],D+'1799,1838-1839,306-308','select the next ref before acquiring its progress lock',
    ['st.fpc[t] = "select"','p \\in st.ftodo[t]'],
    [('fp[t]','p'),('ftodo[t]','@ \\ {p}'),('fpc[t]','"commit"')])
add('RefFinalizeReceiverCommit',[('t','Finalizers')],D+'313-335','atomic dedup, pending guard, pop, status record and downloaded_to_all latch',
    ['st.fpc[t] = "commit"'],
    [('status','m'),('provisional[p]','IF won THEN "none" ELSE @'),('pending[p]','IF won THEN FALSE ELSE @'),
     ('allDone[p[1]]','@ \\/ all'),('fwon[t]','won'),('faccepted[t]','@ \\/ won'),('fall[t]','all'),
     ('cb[t]','IF won THEN Callback("one", p[1]) ELSE @'),('fpc[t]','IF won THEN "one" ELSE "advance"')],
    lets='p == st.fp[t]\nvalue == IF t \\in Confirmers THEN st.consumerResult[p] ELSE "failed"\nwon == st.status[p] = "none" /\\ (t \\notin Confirmers \\/ (st.pending[p] /\\ st.consumerNonce[p]))\nm == IF won THEN [st.status EXCEPT ![p] = value] ELSE st.status\nall == won /\\ ~st.allDone[p[1]] /\\ RefFinished(m, p[1])')
add('RefDownloadedToOneReturned',[('t','Finalizers')],D+'342-357','after guarded downloaded_to_one, independently invoke downloaded_to_all if latched',
    ['st.fpc[t] = "one"','st.cb[t].pc = "done"'],
    [('cb[t]','IF st.fall[t] THEN Callback("all", st.fp[t][1]) ELSE EmptyCB'),('fpc[t]','IF st.fall[t] THEN "all" ELSE "progress"')])
add('RefDownloadedToAllReturned',[('t','Finalizers')],D+'350-357','guarded downloaded_to_all returns to the caller',
    ['st.fpc[t] = "all"','st.cb[t].pc = "done"'], [('cb[t]','EmptyCB'),('fpc[t]','"progress"')])
add('RefFinalizerProgress',[('t','Finalizers')],D+'411-429,510-514','after callback return select receiver truth for progress (separate from final commit)',
    ['st.fpc[t] = "progress"','st.pub[t].pc = "idle"'],
    [('pub[t]','RequestPub(st.fp[t], IF st.status[st.fp[t]] = "success" THEN "completed" ELSE "failed", 0, TRUE)'),('fpc[t]','"advance"')])
add('FinalizerAdvance',[('t','Finalizers')],D+'423-430,504-515,1799-1801,1838-1839','after receiver publication return to the sibling/candidate loop',
    ['st.fpc[t] = "advance"','st.pub[t].pc = "idle"'], [('fpc[t]','"select"')])
add('HandleConfirmMarkActive',[('p','Pairs')],D+'1799-1803','accepted confirmation refreshes transaction clock only, after its callbacks',
    ['st.fpc[Confirm(p)] = "select"','st.ftodo[Confirm(p)] = {}'],
    [('txLast','IF st.faccepted[Confirm(p)] THEN st.now ELSE @'),('fpc[Confirm(p)]','"end"')])
add('HandleCancelLoopDone',[('c','Receivers')],D+'1838-1841','all sibling cancellation attempts returned',
    ['st.fpc[Cancel(c)] = "select"','st.ftodo[Cancel(c)] = {}'], [('fpc[Cancel(c)]','"end"')])
add('FinalizerEndOp',[('t','Confirmers \\cup Cancellers')],D+'1802-1810,1840-1844,835-839','end operation BEFORE requesting finish-if-complete',
    ['st.fpc[t] = "end"'],
    [('ops','@ \\ {t}'),('fpc[t]','"done"'),('finishReady','IF st.faccepted[t] THEN @ \\cup {t} ELSE @')])
add('MonitorBegin',[],D+'1848-1863','capture monitor time before budget operations; no absolute transaction-age deadline',
    ['st.monitorPC = "idle"','st.live','~st.shutdown'], [('monitorNow','st.now'),('monitorPC','"admit"')])
add('MonitorAdmitBudgets',[],D+'1856-1865,822-833','register budget pass as an operation if the transaction is still live',
    ['st.monitorPC = "admit"'],
    [('ops','IF st.live /\\ ~st.closed /\\ (AcquireTimeout > 0 \\/ IdleTimeout > 0) THEN @ \\cup {Budget} ELSE @'),
     ('fpc[Budget]','IF st.live /\\ ~st.closed /\\ (AcquireTimeout > 0 \\/ IdleTimeout > 0) THEN "snapshot" ELSE @'),
     ('monitorPC','IF st.live /\\ ~st.closed /\\ (AcquireTimeout > 0 \\/ IdleTimeout > 0) THEN "budget" ELSE "classify"')])
add('EnforceReceiverBudgetsSnapshot',[],D+'857-873','capture receiver activity once per transaction budget pass under stats lock',
    ['st.fpc[Budget] = "snapshot"'],
    [('budgetLast','st.receiverLast'),('budgetNow','st.monitorNow'),('ftodo[Budget]','Pairs'),('fpc[Budget]','"select"'),('faccepted[Budget]','FALSE')])
add('RefEnforceBudgetSelect',[('p','Pairs')],D+'475-502','select a candidate from declared identities; test acquisition/idle using captured receiver clock',
    ['st.fpc[Budget] = "select"','p \\in st.ftodo[Budget]'],
    [('fp[Budget]','p'),('ftodo[Budget]','@ \\ {p}'),('fpc[Budget]','IF eligible THEN "recheck" ELSE "select"')],
    lets='last == st.budgetLast[p[2]]\neligible == st.status[p] = "none" /\\\n    IF last = -1 THEN AcquireTimeout > 0 /\\ st.budgetNow > AcquireTimeout\n    ELSE IdleTimeout > 0 /\\ st.budgetNow - last > IdleTimeout')
add('RefEnforceBudgetRecheck',[],D+'504-510','freshness recheck under stats lock; release it BEFORE final-status commit',
    ['st.fpc[Budget] = "recheck"'],
    [('fpc[Budget]','IF st.receiverLast[st.fp[Budget][2]] = st.budgetLast[st.fp[Budget][2]] THEN "commit" ELSE "select"')])
add('MonitorBudgetEndOp',[],D+'1864-1871,835-839','finish all budget callbacks and leave gate before classification',
    ['st.fpc[Budget] = "select"','st.ftodo[Budget] = {}'],
    [('ops','@ \\ {Budget}'),('fpc[Budget]','"idle"'),('monitorPC','"classify"')])
add('MonitorNoRetirement',[],D+'1875-1890,1909','classification leaves a live nonexpired transaction, or notices another terminator won',
    ['st.monitorPC = "classify"','~st.live \\/ (~Finished(st.status) /\\ st.monitorNow - st.txLast <= TxTimeout)'],
    [('monitorPC','"idle"')])
add('FinishTransactionIfComplete',[('t','Confirmers \\cup Cancellers')],D+'1411-1425,1525-1541','table-locked single-winner retirement; monotone final-status scan linearizes at successful check',
    ['t \\in st.finishReady','st.live','Finished(st.status)'],
    [('finishReady','@ \\ {t}'),('live','FALSE'),('terminating','TRUE'),('cause','"finished"'),('submitPC','"ready"')])
add('FinishTransactionNotComplete',[('t','Confirmers \\cup Cancellers')],D+'1420-1422','helper observes missing transaction or a ref that is not complete',
    ['t \\in st.finishReady','~st.live \\/ ~Finished(st.status)'], [('finishReady','@ \\ {t}')])
add('MonitorRetireFinished',[],D+'1875-1890,1903-1907','monitor retires a finished transaction and schedules its own inline settlement',
    ['st.monitorPC = "classify"','st.live','Finished(st.status)'],
    [('live','FALSE'),('terminating','TRUE'),('cause','"finished"'),('spc[Inline]','"enter"'),('monitorPC','"settling"')])
add('MonitorRetireTimeout',[],D+'1880-1887,1897-1901','only after not-finished test, retire on sliding inactivity using monitor sampled time',
    ['st.monitorPC = "classify"','st.live','~Finished(st.status)','st.monitorNow - st.txLast > TxTimeout'],
    [('live','FALSE'),('terminating','TRUE'),('cause','"timeout"'),('spc[Inline]','"enter"'),('monitorPC','"settling"')])
add('DeleteTransaction',[],D+'1399-1408,1525-1541','explicit deletion atomically wins table ownership, then runs settlement outside the lock',
    ['st.live'], [('live','FALSE'),('terminating','TRUE'),('cause','"deleted"'),('spc[Inline]','"enter"')],fault='delete')
add('Shutdown',[],D+'1457-1497','atomically clear ownership and receipts; resolve pending waiters with None BEFORE cleanup',
    ['~st.shutdown'],
    [('shutdown','TRUE'),('live','FALSE'),('owner','FALSE'),('retained','FALSE'),
     ('terminating','IF st.live THEN TRUE ELSE @'),('cause','IF st.live THEN "deleted" ELSE @'),
     ('spc[Inline]','IF st.live THEN "enter" ELSE @'),
     ('waiter','IF @ = "pending" THEN "none" ELSE @'),('lateWaiter','IF @ = "pending" THEN "none" ELSE @')],fault='shutdown')

# Progress event construction is one _progress_lock critical section; delivery is outside.
add('RefMakeProgressEvent',[('t','Actors')],D+'526-612','construct or suppress a progress event atomically, latching first terminal state',
    ['st.pub[t].pc = "make"'],
    [('progressStarted','@ \\cup {p}'),('progressOrder[p[1]]','IF p \\notin st.progressStarted THEN Append(@, p[2]) ELSE @'),
     ('progressBytes[p]','IF wasTerminal THEN @ ELSE bytes'),
     ('progressSeq[p]','IF emit THEN @ + 1 ELSE @'),
     ('progressTerminal[p]','IF emit /\\ state \\in TerminalStates THEN state ELSE @'),
     ('pub[t].pc','IF emit THEN "call" ELSE "idle"'),
     ('pub[t].events','IF emit THEN {Event(p, state, st.progressSeq[p]+1, bytes)} ELSE {}')],
    lets='p == st.pub[t].pair\nwasTerminal == st.progressTerminal[p] # "none"\noverride == st.refTerminal[p[1]] # "none" /\\ st.pub[t].want \\notin TerminalStates\nstate == IF override THEN st.refTerminal[p[1]] ELSE st.pub[t].want\ndelta == IF override THEN 0 ELSE st.pub[t].delta\nbytes == st.progressBytes[p] + delta\nemit == ~wasTerminal /\\ (override \\/ st.pub[t].force \\/ p \\notin st.progressStarted \\/ state \\in TerminalStates \\/ delta > 0)')
add('TransactionEmitProgressEvent',[('t','Actors'),('e','st.pub[t].events')],D+'539-542,1004-1013','invoke public source progress callback after releasing progress lock',
    ['st.pub[t].pc = "call"'],
    [('pub[t].events','@ \\ {e}'),('pub[t].current','e'),('pub[t].pc','"return"'),
     ('observedTerminal[e.pair]','IF e.state \\in TerminalStates THEN e.state ELSE @')])
add('TransactionProgressCallbackReturn',[('t','Actors')],D+'1008-1013','progress callback returns or its ordinary Exception is contained; no unmodeled callback mutation',
    ['st.pub[t].pc = "return"'],
    [('pub[t].pc','IF st.pub[t].events = {} THEN "idle" ELSE "call"'),('pub[t].current','EmptyEvent')])
(P/'base.tla').write_text(''.join(parts)+'\\* Generation in progress: settlement follows.\n====\n')
add('CheckedExecutorEnqueue',[],'stream_utils.py:60-78; concurrent/futures/thread.py:199-216','enqueue settlement before submission acknowledgement (brief S3; saved stdlib evidence)',
    ['st.submitPC = "ready"'], [('queued','TRUE'),('submitPC','"enqueued"')])
add('CheckedExecutorSubmitReturn',[],'stream_utils.py:65-66; concurrent/futures/thread.py:199-216','return the Future; the worker may already have started',
    ['st.submitPC = "enqueued"'], [('submitPC','"done"')])
add('CheckedExecutorSubmitRuntimeError',[],'stream_utils.py:71-78; download_service.py:1435-1441','post-enqueue non-shutdown RuntimeError propagates; DownloadService selects fallback without dequeuing',
    ['st.submitPC = "enqueued"'], [('submitPC','"fallback"')],fault='submit')
add('CheckedExecutorSubmitStopped',[],'stream_utils.py:61-64,79-81; download_service.py:1442-1446','executor declines submission before enqueue and returns None',
    ['st.submitPC = "ready"'], [('submitPC','"fallback"')],fault='executorStop')
add('SubmitFinishedSettlementFallback',[],D+'1442-1454','run inline fallback; no settlement-entry dedup latch exists',
    ['st.submitPC = "fallback"'], [('submitPC','"done"'),('spc[Inline]','"enter"')])
add('SettleFinishedTransactionWorker',[],'stream_utils.py:65-78,84-85; download_service.py:1449-1454','a runnable worker dequeues the existing settlement item, even if submission reported error',
    ['st.queued','st.spc[Worker] = "idle"'], [('queued','FALSE'),('spc[Worker]','"enter"')])
add('TransactionDoneDrainBegin',[('t','Settlers')],D+'895-906,841-850','each settlement invocation independently closes gate and establishes its own drain deadline',
    ['st.spc[t] = "enter"'], [('closed','TRUE'),('drainAt[t]','st.now'),('spc[t]','"drain"')])
add('TransactionDoneDrainEmpty',[('t','Settlers')],D+'841-851,910','drain returns normally once all admitted operations ended',
    ['st.spc[t] = "drain"','st.ops = {}'], [('todo[t]','Refs'),('spc[t]','"snapshot"')])
add('TransactionDoneDrainExpired',[('t','Settlers')],D+'846-849,905-910','after the bounded wait, proceed even with outstanding operations',
    ['st.spc[t] = "drain"','st.ops # {}','st.now - st.drainAt[t] >= DrainTimeout'],
    [('drainForced[t]','TRUE'),('todo[t]','Refs'),('spc[t]','"snapshot"')])
add('TransactionDoneSnapshotRef',[('t','Settlers'),('r','Refs')],D+'910,918-927,432-434','copy one complete per-ref status map under that ref lock; refs are snapshotted separately',
    ['st.spc[t] = "snapshot"','r \\in st.todo[t]'],
    [('snapshots[t]','[p \\in Pairs |-> IF p[1] = r THEN st.status[p] ELSE st.snapshots[t][p]]'),('todo[t]','@ \\ {r}')])
add('TransactionDoneComputeOutcome',[('t','Settlers')],D+'918-928; transfer_outcome.py:156-202,242-271','compute strict success and common-receiver quorum from the frozen matrix',
    ['st.spc[t] = "snapshot"','st.todo[t] = {}'],
    [('verdicts[t]','Verdict(st.snapshots[t], st.cause)'),('spc[t]','"terminalProgress"'),('todo[t]','Refs')])
add('TransactionDoneComputeException',[('t','Settlers')],D+'929-933,803-820','contained computation Exception creates an empty fail-closed verdict and still executes cleanup',
    ['st.spc[t] = "snapshot"','st.todo[t] = {}'],
    [('verdicts[t]','FailedVerdict(st.cause)'),('spc[t]','"terminalProgress"'),('todo[t]','Refs')],fault='compute')
add('TransactionDoneTerminalProgress',[('t','Settlers'),('r','Refs')],D+'935-938,544-564,576-612','under one ref lock, set ref-wide terminal override and construct all started-receiver events',
    ['st.spc[t] = "terminalProgress"','r \\in st.todo[t]','st.pub[t].pc = "idle"'],
    [('refTerminal[r]','state'),('progressTerminal','[p \\in Pairs |-> IF p \\in eligible THEN state ELSE st.progressTerminal[p]]'),
     ('progressSeq','[p \\in Pairs |-> st.progressSeq[p] + IF p \\in eligible THEN 1 ELSE 0]'),
     ('pub[t]','[EmptyPub EXCEPT !.pc = IF eligible = {} THEN "idle" ELSE "call", !.events = {Event(p, state, st.progressSeq[p]+1, st.progressBytes[p]) : p \\in eligible}]'),
     ('todo[t]','@ \\ {r}')],
    lets='state == DoneProgress(st.cause)\neligible == {p \\in st.progressStarted : p[1] = r /\\ st.progressTerminal[p] = "none"}')
add('TransactionDoneProgressReturned',[('t','Settlers')],D+'935-953','finish terminal progress callbacks before capturing the base objects',
    ['st.spc[t] = "terminalProgress"','st.todo[t] = {}','st.pub[t].pc = "idle"'],
    [('spc[t]','"baseObjects"'),('todo[t]','Refs')])
add('TransactionDoneSnapshotBaseObject',[('t','Settlers'),('r','Refs')],D+'948-953','snapshot each infrastructure source reference before object callbacks; another settlement may already release it',
    ['st.spc[t] = "baseObjects"','r \\in st.todo[t]'],
    [('baseObjects[t][r]','st.sourceHeld[r]'),('todo[t]','@ \\ {r}')])
add('TransactionDoneObjectsBegin',[('t','Settlers')],D+'953-955','begin per-object transaction_done callback loop',
    ['st.spc[t] = "baseObjects"','st.todo[t] = {}'], [('spc[t]','"objects"'),('todo[t]','Refs')])
add('TransactionDoneObjectCallback',[('t','Settlers'),('r','Refs')],D+'955-964','prepare one guarded object transaction_done callback',
    ['st.spc[t] = "objects"','r \\in st.todo[t]','st.cb[t].pc = "idle"'],
    [('cb[t]','Callback("objectDone", r)'),('todo[t]','@ \\ {r}')])
add('TransactionDoneObjectReturned',[('t','Settlers')],D+'955-964','return to loop after this object hook returned or raised',
    ['st.spc[t] = "objects"','st.cb[t].pc = "done"'], [('cb[t]','EmptyCB')])
add('TransactionDoneTransactionCallback',[('t','Settlers')],D+'966-975','invoke configured transaction_done_cb with this invocation\'s base-object snapshot',
    ['st.spc[t] = "objects"','st.todo[t] = {}','st.cb[t].pc = "idle"'],
    [('cb[t]','Callback("txDone", "-")'),('spc[t]','"txCallback"')])
add('TransactionDoneOutcomeCallback',[('t','Settlers')],D+'977-978','after transaction callback return, invoke outcome_cb BEFORE source releases',
    ['st.spc[t] = "txCallback"','st.cb[t].pc = "done"'],
    [('cb[t]','Callback("outcome", "-")'),('spc[t]','"outcomeCallback"')])
add('TransactionDoneReleaseBegin',[('t','Settlers')],D+'977-989','finally begins release loop despite guarded callback Exceptions',
    ['st.spc[t] = "outcomeCallback"','st.cb[t].pc = "done"'],
    [('cb[t]','EmptyCB'),('todo[t]','Refs'),('spc[t]','"release"')])
add('TransactionDoneRelease',[('t','Settlers'),('r','Refs')],D+'985-989','prepare each independently guarded release attempt',
    ['st.spc[t] = "release"','r \\in st.todo[t]','st.cb[t].pc = "idle"'],
    [('cb[t]','Callback("release", r)'),('todo[t]','@ \\ {r}')])
add('TransactionDoneReleaseReturned',[('t','Settlers')],D+'988-989','continue release loop after this source release returned or raised',
    ['st.spc[t] = "release"','st.cb[t].pc = "done"'], [('cb[t]','EmptyCB')])
add('InvokeCallbackSafely',[('t','Actors'),('arg','{CallbackArgs(t)}')],D+'645-655,342-356,958-989','enter user hook; observer counts invocations/attempts, independently of return or exception',
    ['st.cb[t].pc = "ready"'],
    [('cb[t].pc','"running"'),
     ('objectDoneCalls','IF k = "objectDone" THEN [st.objectDoneCalls EXCEPT ![r] = @ + 1] ELSE st.objectDoneCalls'),
     ('doneCalls','IF k = "txDone" THEN @ + 1 ELSE @'),('outcomeCbCalls','IF k = "outcome" THEN @ + 1 ELSE @'),
     ('releaseAttempts','IF k = "release" THEN [st.releaseAttempts EXCEPT ![r] = @ + 1] ELSE st.releaseAttempts'),
     ('effectsAfterReceipt','@ \\/ (k \\in {"objectDone", "txDone", "outcome", "release"} /\\ (st.waiter = "receipt" \\/ st.lateWaiter = "receipt"))')],
    lets='k == st.cb[t].kind\nr == st.cb[t].ref')
add('ReleaseSourceReference',[('t','Settlers')],'cacheable.py:109-120; download_service.py:193-201,988-989','owned-source release drops only the infrastructure reference, before its hook returns',
    ['st.cb[t].pc = "running"','st.cb[t].kind = "release"'],
    [('sourceHeld[st.cb[t].ref]','FALSE'),('cb[t].pc','"releaseReturn"')])
add('CallbackReturn',[('t','Actors')],D+'645-655','finite callback returns; no caller phase advances until this return',
    ['st.cb[t].pc = "releaseReturn" \\/ (st.cb[t].pc = "running" /\\ st.cb[t].kind # "release")'],
    [('cb[t].pc','"done"')])
add('CallbackException',[('t','Actors')],D+'645-655,985-989','ordinary callback/release Exception is contained; already visible effects are not undone',
    ['st.cb[t].pc = "running"'], [('cb[t].pc','"done"'),('callbackErrors','@ + 1')],fault='callback')
add('TransactionDoneRecordReady',[('t','Settlers')],D+'988-999','all this invocation\'s release attempts have returned before on_outcome recording',
    ['st.spc[t] = "release"','st.todo[t] = {}','st.cb[t].pc = "idle"'], [('spc[t]','"record"')])
add('RecordOutcome',[('t','Settlers')],D+'1579-1595,998-1000','owner-guarded single receipt write; resolve pending waiters atomically with recording',
    ['st.spc[t] = "record"','st.owner'],
    [('owner','FALSE'),('receiptWrites','@ + 1'),('receipt','st.verdicts[t]'),('retained','TRUE'),('recordAt','st.now'),('recordedBy','t'),
     ('waiter','IF @ = "pending" THEN "receipt" ELSE @'),('waiterOutcome','IF st.waiter = "pending" THEN st.verdicts[t] ELSE @'),
     ('lateWaiter','IF @ = "pending" THEN "receipt" ELSE @'),('lateOutcome','IF st.lateWaiter = "pending" THEN st.verdicts[t] ELSE @'),('spc[t]','"complete"')])
add('RecordOutcomeDrop',[('t','Settlers')],D+'1582-1585,998-1000','ownership consumed by another record or cleared by shutdown: discard duplicate receipt',
    ['st.spc[t] = "record"','~st.owner'], [('spc[t]','"complete"')])
add('TransactionDoneComplete',[('t','Settlers')],D+'1000-1002','set settlement_complete after recording returns; this is not an entry latch',
    ['st.spc[t] = "complete"'], [('settlementComplete','TRUE'),('spc[t]','"markerRead"')])
add('SyncTerminationMarkerRead',[('t','Settlers')],D+'1500-1505','snapshot whether admitted operations remain under operation lock',
    ['st.spc[t] = "markerRead"'], [('markerLeaked[t]','st.ops # {}'),('spc[t]','"markerWrite"')])
add('SyncTerminationMarkerWrite',[('t','Settlers')],D+'1506-1510','sustain or clear marker under table lock using sampled operation state',
    ['st.spc[t] = "markerWrite"'],
    [('terminating','st.markerLeaked[t] \\/ ~st.settlementComplete'),('spc[t]','"done"')])
add('ReapTerminationMarker',[],D+'1513-1522','monitor removes a quiescent marker; remaining settlement duplication is not counted by this latch',
    ['st.terminating','st.settlementComplete','st.ops = {}'], [('terminating','FALSE')])
add('ExpireOutcome',[],D+'1611-1619; transfer_outcome.py:181-182','remove retained receipt after strict greater-than TTL; previously resolved waiters retain their value',
    ['st.retained','st.now - st.recordAt > ReceiptTTL'], [('retained','FALSE')])
add('GetTransferWaiter',[],D+'1544-1565','attach a second observer; unswept expired receipt still resolves it, exactly as current API',
    ['st.lateWaiter = "unregistered"'],
    [('lateWaiter','IF st.retained THEN "receipt" ELSE IF st.owner THEN "pending" ELSE "none"'),
     ('lateOutcome','IF st.retained THEN st.receipt ELSE EmptyVerdict')])
add('WaitForResultTransfers',[],'nvflare/client/cell/api.py:624-648','minimal caller barrier: only a non-None strict COMPLETED receipt permits success',
    ['st.caller = "waiting"','st.waiter # "pending"'],
    [('caller','IF st.waiter = "receipt" /\\ st.waiterOutcome.status = "completed" THEN "success" ELSE "error"')])
add('AdvanceTime',[],D+'441-442,774-775,843-849,1850,1909','advance abstract monotone wall time; monitor execution remains independent',
    ['TRUE'], [('now','@ + 1')],fault='time')

add('HandleDownloadProduceError',[('p','Pairs')],D+'1716,1724-1732','produce returns ERROR as an ordinary functional outcome, provisionally awaiting receiver truth',
    ['st.pullPC[p] = "produce"','st.pub[Pull(p)].pc = "idle"'],
    [('rc[p]','"error"'),('pullPC[p]','"served"')],fault='produce')
add('ConsumerReceiveProducerError',[('p','Pairs')],D+'2260-2265,2285-2289','terminal ERROR carries nonce; prepare FAILED confirmation without download_completed',
    ['st.consumer[p] = "waiting"','st.reply[p] = "error"'],
    [('reply[p]','"none"'),('consumerNonce[p]','st.replyNonce[p]'),('consumerResult[p]','"failed"'),('consumer[p]','"confirmReady"')])

add('DownloadRequestWorkerStart',[('p','Pairs')],D+'2166-2182,2300-2305,2312-2313','the submitted pipeline future starts before remote admission; cancel can no longer erase the request',
    ['st.pullPC[p] = "sent"','~st.futureStarted[p]'], [('futureStarted[p]','TRUE')])

# Extra observer/cached-local fields referenced by settlement actions.
parts[0] = parts[0].replace('recordAt |-> 0, waiter', 'recordAt |-> 0, recordedBy |-> Inline,\n          markerLeaked |-> [t \\in Settlers |-> FALSE], waiter')
# Type every top-level field, including every PC and cached snapshot. No desired safety property is an assumption.
T = {}
def types(names,typ):
    for n in names.split(): T[n]=typ
# Download/receiver state
for names,typ in [
('now txLast budgetNow monitorNow recordAt callbackErrors receiptWrites doneCalls outcomeCbCalls','Nat'),
('live owner closed terminating settlementComplete shutdown queued effectsAfterReceipt retained','BOOLEAN'),
('status consumerResult provisional','[Pairs -> FinalStatuses]'),('pending nonce replyNonce consumerNonce futureStarted','[Pairs -> BOOLEAN]'),
('allDone sourceHeld','[Refs -> BOOLEAN]'),('acquired abandoned cancelWire','SUBSET Receivers'),
('tombstoneAt','Int'),
('receiverLast budgetLast','[Receivers -> Int]'),('refLast','[Pairs -> Int]'),
('ops','SUBSET (Pullers \\cup Finalizers)'),
('pullTime index progressBytes progressSeq','[Pairs -> Nat]'),
('pullPC','[Pairs -> {"idle","sent","markTx","markRef","markReceiver","startProgress","produce","dataProgress","served","terminalProgress","end","done"}]'),
('rc reply','[Pairs -> {"none","data","eof","error","exception","missing"}]'),
('consumer','[Pairs -> {"new","waiting","data","consuming","completing","confirmReady","done","failed"}]'),
('confirmWire progressStarted','SUBSET Pairs'),
('fpc','[Finalizers -> {"idle","acquired","select","commit","one","all","progress","advance","end","done","snapshot","recheck"}]'),
('fp','[Finalizers -> (Pairs \\cup {NullPair})]'),('ftodo','[Finalizers -> SUBSET Pairs]'),
('fwon faccepted fall','[Finalizers -> BOOLEAN]'),('finishReady','SUBSET (Confirmers \\cup Cancellers)'),
('monitorPC','{"idle","admit","budget","classify","settling"}'),
('progressOrder','[Refs -> Seq(Receivers)]'),
('progressTerminal observedTerminal','[Pairs -> (TerminalStates \\cup {"none"})]'),
('refTerminal','[Refs -> (TerminalStates \\cup {"none"})]'),
('pub','[Actors -> PubType]'),('cb','[Actors -> CBType]'),
('cause','{"none","finished","timeout","deleted"}'),('submitPC','{"idle","ready","enqueued","fallback","done"}'),
('spc','[Settlers -> {"idle","enter","drain","snapshot","terminalProgress","baseObjects","objects","txCallback","outcomeCallback","release","record","complete","markerRead","markerWrite","done"}]'),
('drainAt','[Settlers -> Nat]'),('drainForced markerLeaked','[Settlers -> BOOLEAN]'),('todo','[Settlers -> SUBSET Refs]'),
('snapshots','[Settlers -> [Pairs -> FinalStatuses]]'),('verdicts','[Settlers -> VerdictType]'),
('baseObjects','[Settlers -> [Refs -> BOOLEAN]]'),('objectDoneCalls releaseAttempts','[Refs -> Nat]'),
('receipt waiterOutcome lateOutcome','VerdictType'),('recordedBy','Settlers'),
('waiter','{"pending","receipt","none"}'),('lateWaiter','{"unregistered","pending","receipt","none"}'),
('caller','{"waiting","success","error"}')]: types(names,typ)
parts.append(r'''
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
''')
parts.append('    /\\ DOMAIN st = {'+', '.join('"'+n+'"' for n in sorted(T))+'}\n')
parts.append('\n'.join('    /\\ st.'+n+' \\in '+typ for n,typ in sorted(T.items()))+'\n')
parts.append(r'''
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
''')
def call(a): return a['name'] + ('('+', '.join(n for n,d in a['params'])+')' if a['params'] else '')
def quantified(a,expr=None):
    b=expr or call(a)
    for n,d in reversed(a['params']): b='\\E '+n+' \\in '+d+' : ('+b+')'
    return b
normal=[a for a in A if not a['fault']]
faults=[a for a in A if a['fault']]
parts.append('\nReactiveNext ==\n'+'\n'.join('    \\/ '+quantified(a) for a in normal)+'\n')
parts.append('\nFaultNext ==\n'+'\n'.join('    \\/ '+quantified(a) for a in faults)+'\n')
parts.append(r'''
Next == ReactiveNext \/ FaultNext
Spec == Init /\ [][Next]_vars
\* Conditional scheduling contract: fair enabled action instances (including
\* callback return and queued-worker execution) and advancing time. No finite
\* real-world wall-clock promise or fairness for loss/exception injections.
''')
# Weak fairness for every reactive action INSTANCE prevents one actor starving another.
parts.append('SettlementFairness ==\n    /\\ WF_vars(AdvanceTime)\n')
for a in normal:
    # Progress invoke event is finite; fairness at actor granularity is sufficient.
    pars=[(n,d) for n,d in a['params'] if n not in {'e','arg'}]
    dynamic=[(n,d) for n,d in a['params'] if n in {'e','arg'}]
    f=call(a)
    for n,d in reversed(dynamic): f='\\E '+n+' \\in '+d+' : ('+f+')'
    f='WF_vars('+f+')'
    for n,d in reversed(pars): f='\\A '+n+' \\in '+d+' : ('+f+')'
    parts.append('    /\\ '+f+'\n')
parts.append(r'''
FairSpec == Spec /\ SettlementFairness
EventualSettlementObservation == (<>~st.live) => <>(st.waiter # "pending")
=============================================================================
''')
(P/'base.tla').write_text(''.join(parts))
base_cfg='''\\* Phase 1: main explicit-identity, receiver-confirmed contract.
SPECIFICATION Spec
CONSTANTS
  Refs = {ref1, ref2}
  RefOrder <- DefaultRefOrder
  FirstRegisteredRef = ref1
  Receivers = {receiver1, receiver2}
  ChunkCount = 1
  AcquireTimeout = 3
  IdleTimeout = 3
  TxTimeout = 5
  DrainTimeout = 2
  ReceiptTTL = 4
  FinishedRefsTTL = 9
  MinReceivers = 1
CHECK_DEADLOCK FALSE
INVARIANTS
  TypeOK
  FinalStatusStructure
  AllDoneStructure
  SingleReceipt
  ConfirmedSuccess
  OutcomeAggregation
  ReceiptFollowsOwnCleanup
  CallerRequiresCompleted
  ClosedAfterRetirement
\\* Scenario invariants are enabled in targeted MC_hunt configs after conformance.
\\* SingleSettlementEffects
\\* NoSettlementEffectsAfterReceipt
\\* CompletedProgressHasReceiverSuccess
'''
(P/'base.cfg').write_text(base_cfg)
(P/'action-map.json').write_text(json.dumps(A,indent=2)+'\n')
# Phase 2: bound only injected exceptions/loss/deletion/shutdown/time, never reactive continuations.
categories=sorted({a['fault'] for a in faults})
mc=[r'''-------------------------------- MODULE MC --------------------------------
EXTENDS base
Original == INSTANCE base
CONSTANTS TimeLimit, ConsumerLimit, ProduceLimit, LossLimit, DeleteLimit,
          ShutdownLimit, SubmitLimit, ExecutorStopLimit, CallbackLimit,
          ComputeLimit, MessageLimit
VARIABLE faultCounts
mcvars == <<st, faultCounts>>
''']
limit={x:x[0].upper()+x[1:]+'Limit' for x in categories}
for a in faults:
    sig='MC'+a['name']+('('+', '.join(n for n,d in a['params'])+')' if a['params'] else '')
    orig='Original!'+call(a)
    mc.append('\\* '+a['source']+': bound the injected '+a['fault']+' choice only.\n'+sig+' ==\n')
    mc.append('    /\\ faultCounts.'+a['fault']+' < '+limit[a['fault']]+'\n    /\\ '+orig+'\n')
    mc.append("    /\\ faultCounts' = [faultCounts EXCEPT !."+a['fault']+' = @ + 1]\n\n')
mc.append('MCInit == Init /\\ faultCounts = ['+', '.join(x+' |-> 0' for x in categories)+']\n')
mc.append(r'''
\* CFG overrides route only FaultNext through wrappers. All normal action
\* instances (including callback return, dequeue, drain expiry, end_op and
\* monitor budget checks) are unrestricted and preserve fault counters.
MCNext == (ReactiveNext /\ UNCHANGED faultCounts) \/ FaultNext
MCSpec == MCInit /\ [][MCNext]_mcvars
Symmetry == Permutations(Receivers)
\* A display projection is useful, but NOT enabled as TLC VIEW: fault budgets
\* change future reachability, so merging states that differ in them is unsafe.
ObservedView == st
MCTypeOK == TypeOK /\ faultCounts \in [''')
mc.append(', '.join(x+' : 0..'+limit[x] for x in categories)+']\n')
mc.append(r'''
MessageCount == Cardinality(st.confirmWire) + Cardinality(st.cancelWire)
                + Cardinality({p \in Pairs : st.pullPC[p] = "sent"})
                + Cardinality({p \in Pairs : st.reply[p] # "none"})
MessageConstraint == MessageCount <= MessageLimit
\* Liveness is intentionally conditional and separate from safety hunts.
\* After retirement, sufficient Tick budget OR eventual completion of every
\* admitted operation lets each runnable, finite callback chain settle.
\* The unbounded base FairSpec states the clean scheduling obligation.
MCFairSpec == MCSpec /\ SettlementFairness
=============================================================================
''')
(P/'MC.tla').write_text(''.join(mc))
def cfg(refs=2,receivers=2,time=8,consumer=2,produce=1,loss=1,delete=1,shutdown=1,submit=1,executorStop=1,callback=2,compute=1,acquire=3,idle=3,tx=5,drain=2,targets=None,standard=False):
    opts=locals()
    s='\\* Fixed fully registered payload, explicit identities, confirmation enabled.\nSPECIFICATION MCSpec\nCONSTANTS\n'
    s+='  Refs = {'+', '.join('ref'+str(i+1) for i in range(refs))+'}\n'
    s+='  FirstRegisteredRef = ref1\n'
    s+='  RefOrder <- '+('OneRefOrder' if refs == 1 else 'TwoRefOrder')+'\n'
    s+='  Receivers = {'+', '.join('receiver'+str(i+1) for i in range(receivers))+'}\n'
    s+=f'  ChunkCount = 1\n  AcquireTimeout = {acquire}\n  IdleTimeout = {idle}\n  TxTimeout = {tx}\n  DrainTimeout = {drain}\n  ReceiptTTL = 4\n  FinishedRefsTTL = 9\n  MinReceivers = 1\n'
    s+=''.join('  '+limit[x]+' = '+str(opts[x])+'\n' for x in categories)
    s+='  MessageLimit = '+str(4*refs*receivers+receivers)+'\n'
    s+='\n\\* Counter wrappers retain the unmodified base actions via Original!Name.\n'
    s+=''.join(a['name']+' <- MC'+a['name']+'\n' for a in faults)
    s+='\nSYMMETRY Symmetry\nCONSTRAINT MessageConstraint\nCHECK_DEADLOCK FALSE\n'
    core=['TypeOK','SingleReceipt','ConfirmedSuccess','OutcomeAggregation','ReceiptFollowsOwnCleanup','CallerRequiresCompleted']
    s+='\n\\* Core safety\nINVARIANTS\n'+''.join('  '+x+'\n' for x in core)
    if standard:
        s+='\n\\* Structural invariants for convergence\nINVARIANTS\n  MCTypeOK\n  FinalStatusStructure\n  AllDoneStructure\n  ClosedAfterRetirement\n'
        s+='\n\\* Scenario hypotheses: deliberately disabled during convergence.\n'
        s+='\\* INVARIANTS SingleSettlementEffects NoSettlementEffectsAfterReceipt\n\\* INVARIANT CompletedProgressHasReceiverSuccess\n'
    if targets: s+='\n\\* Targeted scenario hypotheses\nINVARIANTS\n'+''.join('  '+x+'\n' for x in targets)
    return s
(P/'MC.cfg').write_text(cfg(standard=True))
(P/'MC_hunt_s1_progress.cfg').write_text('\\* S1 / MC-2: acquired pipelined request survives consume failure.\n'+cfg(refs=1,receivers=1,time=0,consumer=1,produce=0,loss=0,delete=0,shutdown=0,submit=0,executorStop=0,callback=0,compute=0,acquire=0,idle=0,targets=['CompletedProgressHasReceiverSuccess']))
(P/'MC_hunt_s3_settlement.cfg').write_text('\\* S3 + S5 / MC-1: post-enqueue failure, queued worker and inline fallback.\n'+cfg(refs=1,receivers=1,time=0,consumer=0,produce=0,loss=0,delete=0,shutdown=0,submit=1,executorStop=0,callback=0,compute=0,acquire=0,idle=0,targets=['SingleSettlementEffects']))
(P/'MC_hunt_s3_after_receipt.cfg').write_text('\\* S3 + S5 / MC-1: isolate later effects; an earlier duplicate-count violation must not mask this target.\n'+cfg(refs=1,receivers=1,time=0,consumer=0,produce=0,loss=0,delete=0,shutdown=0,submit=1,executorStop=0,callback=1,compute=0,acquire=0,idle=0,targets=['NoSettlementEffectsAfterReceipt']))
(P/'MC_hunt_s4_budgets.cfg').write_text('\\* S4 with S2/S5: current clock/aggregation/drain contracts, not a reverted-fix hunt.\n\\* Receiver budgets exceed sliding transaction inactivity; healthy requests can still keep it live.\n'+cfg(time=6,consumer=1,produce=1,loss=1,delete=1,shutdown=1,submit=0,executorStop=0,callback=1,compute=1,acquire=3,idle=3,tx=2,drain=2))
# Phase 3: linear Category A trace, with every semantic boundary instrumented.
trace=[r'''------------------------------- MODULE Trace -------------------------------
EXTENDS base, Json, IOUtils
VARIABLE l
tracevars == <<st, l>>
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
RawLog == ndJsonDeserialize(JsonFile)
Tagged == SelectSeq(RawLog, LAMBDA e : IF "tag" \in DOMAIN e THEN e.tag = "nvflare-transfer" ELSE FALSE)
Header == Tagged[1]
TraceLog == Tail(Tagged)
SeqSet(xs) == {xs[i] : i \in 1..Len(xs)}

\* Decode by the known state-field schema, not by applying STRING/Int
\* membership to arbitrary JSON objects (TLC deliberately rejects that).
\* Atoms, identity tuples and ordinary records stay native JSON values.
DecodeSet(v) ==
    IF Assert(v.__tla = "set", "expected a tagged set") THEN SeqSet(v.items) ELSE {}
DecodeFn(v) ==
    IF "__tla" \in DOMAIN v THEN
        LET entries == v.entries
            keys == {entries[i].key : i \in 1..Len(entries)}
        IN IF Assert(v.__tla = "function" /\ Cardinality(keys) = Len(entries),
                     "invalid function tag or duplicate keys")
           THEN [k \in keys |->
                 LET i == CHOOSE i \in 1..Len(entries) : entries[i].key = k
                 IN entries[i].value]
           ELSE [k \in {} |-> k]
    ELSE v
DecodeVerdict(v) == [v EXCEPT !.matrix = DecodeFn(@)]
DecodePub(v) == [v EXCEPT !.events = DecodeSet(@)]
DecodeField(name, v) ==
    CASE name \in {"receipt", "waiterOutcome", "lateOutcome"} -> DecodeVerdict(v)
      [] name = "verdicts" -> LET f == DecodeFn(v) IN [t \in DOMAIN f |-> DecodeVerdict(f[t])]
      [] name = "pub" -> LET f == DecodeFn(v) IN [t \in DOMAIN f |-> DecodePub(f[t])]
      [] name \in {"baseObjects", "snapshots"} -> LET f == DecodeFn(v) IN [t \in DOMAIN f |-> DecodeFn(f[t])]
      [] name \in {"ftodo", "todo"} -> LET f == DecodeFn(v) IN [t \in DOMAIN f |-> DecodeSet(f[t])]
      [] name \in {"acquired", "abandoned", "cancelWire", "ops", "confirmWire", "progressStarted", "finishReady"} -> DecodeSet(v)
      [] name \in {"status", "provisional", "consumerResult", "pending", "nonce", "replyNonce", "consumerNonce",
                    "futureStarted", "allDone", "sourceHeld", "receiverLast", "budgetLast", "refLast", "pullTime", "index",
                    "progressBytes", "progressSeq", "progressOrder", "pullPC", "rc", "reply", "consumer", "fpc", "fp",
                    "fwon", "faccepted", "fall", "progressTerminal", "observedTerminal", "refTerminal", "cb",
                    "spc", "drainAt", "drainForced", "markerLeaked", "objectDoneCalls", "releaseAttempts"} -> DecodeFn(v)
      [] OTHER -> v
Decode(v) == [field \in DOMAIN v |-> DecodeField(field, v[field])]
DecodeCallbackArg(t, v) ==
    IF st.cb[t].kind = "outcome" THEN DecodeVerdict(v)
    ELSE IF st.cb[t].kind = "txDone" THEN [v EXCEPT !.sources = DecodeFn(@)]
    ELSE v

TraceRefs == SeqSet(Header.config.refs)
TraceRefOrder == Header.config.refs
TraceFirstRegisteredRef == Header.config.refs[1]
TraceReceivers == SeqSet(Header.config.receivers)
TraceChunkCount == Header.config.chunk_count
TraceAcquireTimeout == Header.config.acquire_timeout
TraceIdleTimeout == Header.config.idle_timeout
TraceTxTimeout == Header.config.tx_timeout
TraceDrainTimeout == Header.config.drain_timeout
TraceReceiptTTL == Header.config.receipt_ttl
TraceFinishedRefsTTL == Header.config.finished_refs_ttl
TraceMinReceivers == Header.config.min_receivers
logline == TraceLog[l]
''']
trace.append('RequiredFields(name) ==\n    CASE '+ '\n      [] '.join('name = "'+a['name']+'" -> {'+', '.join('"'+f+'"' for f in a['fields'])+'}' for a in A)+'\n      [] OTHER -> {}\n')
trace.append(r'''
IsEvent(name, argNames) ==
    /\ l <= Len(TraceLog)
    /\ DOMAIN logline = {"tag", "tx", "n", "event", "args", "post"}
    /\ logline.tag = "nvflare-transfer"
    /\ logline.tx = Header.tx
    /\ logline.n = l
    /\ logline.event = name
    /\ DOMAIN logline.args = argNames
ValidatePostState(name) ==
    LET captured == Decode(logline.post)
        required == RequiredFields(name)
    IN /\ required # {}
       /\ DOMAIN captured = required
       /\ \A field \in required : st'[field] = captured[field]

TraceInit ==
    /\ Init
    /\ l = 1
    /\ Header.event = "init"
    /\ Header.schema = 1
    /\ Header.source_sha = "53ba7ee567468ea7971dad4faccef13c6cb35dc2"
    /\ Header.config.receiver_mode = "explicit"
    /\ Header.config.producer_confirm = TRUE
    /\ Header.config.consumer_confirm = TRUE
    /\ Header.config.progress_interval = 0
    /\ Header.config.progress_enabled = TRUE
    /\ Header.config.pipeline_enabled = TRUE
    /\ Header.config.source_profile = "owned_release"
    /\ Header.config.registration_frozen = TRUE
    /\ Decode(Header.post) = st

''')
for a in A:
    trace.append('\\* '+a['source']+': same complete base action and mandatory observed post-state.\n')
    trace.append('Trace'+a['name']+' ==\n')
    if a['params']:
        trace.append('    LET '+'\n        '.join(n+' == '+('DecodeCallbackArg(t, logline.args.arg)' if n == 'arg' else 'logline.args.'+n) for n,d in a['params'])+'\n    IN\n')
    trace.append('    /\\ IsEvent("'+a['name']+'", {'+', '.join('"'+n+'"' for n,d in a['params'])+'})\n')
    trace.extend('    /\\ '+n+' \\in '+d+'\n' for n,d in a['params'])
    trace.append('    /\\ '+call(a)+'\n    /\\ ValidatePostState("'+a['name']+'")\n    /\\ l\' = l + 1\n\n')
trace.append('TraceStep ==\n'+'\n'.join('    \\/ Trace'+a['name'] for a in A)+'\n')
trace.append(r'''
\* No silent actions: every base action, including clock and executor queue
\* publication, has an explicit event. Missing boundaries must not be guessed.
TraceNext ==
    IF l <= Len(TraceLog) THEN TraceStep ELSE UNCHANGED tracevars
\* Fairness prevents an arbitrary stuttering behavior from rejecting a matched
\* finite trace. At an unmatchable event no action is enabled, so TraceMatched
\* still fails. Only the fully consumed suffix may stutter successfully.
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
''')
(P/'Trace.tla').write_text(''.join(trace))
(P/'Trace.cfg').write_text('''\\* Actual implementation traces go in ../traces; JSON overrides the file path.
SPECIFICATION TraceSpec
CONSTANTS
  Refs <- TraceRefs
  RefOrder <- TraceRefOrder
  FirstRegisteredRef <- TraceFirstRegisteredRef
  Receivers <- TraceReceivers
  ChunkCount <- TraceChunkCount
  AcquireTimeout <- TraceAcquireTimeout
  IdleTimeout <- TraceIdleTimeout
  TxTimeout <- TraceTxTimeout
  DrainTimeout <- TraceDrainTimeout
  ReceiptTTL <- TraceReceiptTTL
  FinishedRefsTTL <- TraceFinishedRefsTTL
  MinReceivers <- TraceMinReceivers
CHECK_DEADLOCK FALSE
INVARIANTS
  TypeOK
  FinalStatusStructure
  AllDoneStructure
  SingleReceipt
  ConfirmedSuccess
  OutcomeAggregation
  ReceiptFollowsOwnCleanup
  CallerRequiresCompleted
  ClosedAfterRetirement
PROPERTIES
  TraceMatched
\\* Scenario hypotheses are checked in hunts after conformance, not assumed here.
''')
# Phase 4: action-to-source contract, generated from the same action metadata
# used for the mandatory Trace post-state fields (not from a guessed inventory).
instrument=[r'''# Instrumentation specification: nvflare-transfer

Source pin `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Source root `/home/ubuntu/nvflare-runs-20260913/source-transfer`; unqualified Python filenames below are under `nvflare/fuel/f3/streaming/`. The executor's queue-before-start boundary is Python 3.14.4 `concurrent/futures/thread.py:199-237`, matching the saved stdlib evidence and `stream_utils_test.py:143-167`.

This document specifies instrumentation; it does not claim a harness was installed or traces collected. Category A uses one globally ordered NDJSON file, with explicit semantic steps for threaded callbacks. Every base action has exactly one event name and one full-action Trace wrapper; there are no silent actions.

## 1. Trace event schema

Files belong in `../traces/` relative to `spec/`. Default: `../traces/trace.ndjson`. `IOEnv.JSON` selects another per-run file. Use the experiment's TLA and CommunityModules jars. `Trace.cfg` enables `TraceMatched` unconditionally; an event that cannot advance the cursor must fail conformance. Fairness excludes arbitrary premature stuttering, without making an unmatchable event pass.

The first tagged line is a bootstrap header:

```json
{"tag":"nvflare-transfer","event":"init","schema":1,"source_sha":"53ba7ee567468ea7971dad4faccef13c6cb35dc2","tx":"actual-transaction-id","config":{"refs":["actual-ref-a","actual-ref-b"],"receivers":["site-a","site-b"],"chunk_count":1,"acquire_timeout":3,"idle_timeout":3,"tx_timeout":5,"drain_timeout":2,"receipt_ttl":4,"finished_refs_ttl":9,"min_receivers":1,"receiver_mode":"explicit","producer_confirm":true,"consumer_confirm":true,"progress_interval":0,"progress_enabled":true,"pipeline_enabled":true,"source_profile":"owned_release","registration_frozen":true},"post":"REPLACE_WITH_COMPLETE_ENCODED_INITIAL_STATE"}
```

This header is a schema illustration, **not a runnable trace**: `post` must contain the complete observed/normalized initial state, including all explicitly initialized continuation/observer fields from `base.Init`. No field may be filled by assuming the desired invariant. Record bootstrap after every ref has been registered and the first waiter attached, before exposing refs or starting monitor work. Freeze the controlled test clock during registration so transaction/ref creation times normalize to zero. `refs` preserves registration order; `receivers` contains actual distinct declared identities. Capture actual effective confirmation switches, count/identities, budgets, progress settings and source profile. Disabled receiver budgets normalize Python None to zero. Check the header against those captured API arguments; do not label count-only/legacy runs as this profile.

Subsequent events have **exactly** these keys:

```json
{"tag":"nvflare-transfer","tx":"actual-transaction-id","n":1,"event":"DownloadObjectStart","args":{"p":["actual-ref-a","site-a"]},"post":{"consumer":{"__tla":"function","entries":[{"key":["actual-ref-a","site-a"],"value":"waiting"}]},"pullPC":{"__tla":"function","entries":[{"key":["actual-ref-a","site-a"],"value":"sent"}]}}}
```

The event example illustrates encoding for one pair. In a two-ref/two-receiver run, both function fields must contain **all four pairs**, including unchanged entries; otherwise conformance rejects them. `n` starts at 1 after bootstrap and increases by one. Filter by tag only; event names from the tagged transaction must never be silently discarded. `tx` always equals the header transaction id.

Parameters:

- `p = [ref_id, receiver_id]`; `r = ref_id`; `c = receiver_id`.
- `t = [kind, ref_id, receiver_id]`, with `kind` pull/confirm for pair workers. Cancel uses `["cancel","-",receiver_id]`; budget/inline/worker use `[kind,"-","-"]`. `-` is reserved and cannot be a real identity.
- `e` is the actual source-progress event projected to `{pair,state,seq,bytes}`. Use the callback's event object, including its latched sequence and byte count, not a fresh receiver-state read. Normalize field names only.
- `arg` on `InvokeCallbackSafely` captures actual hook arguments: downloaded_to_one `{receiver,status}`; downloaded_to_all/release `[]`; object transaction_done `{tx:"tx",status}`; transaction callback `{tx:"tx",status,sources:<ref-to-presence function>}`; outcome callback the projected verdict record below. The single modeled tx id is normalized to `"tx"` inside arguments while the envelope retains its real id. Source presence means the captured argument is that registered source object, not just an arbitrary non-None value. `CallbackArgs` checks these observations against the corresponding snapshot.

JSON encoding is lossless for the model's value types:

- Strings, Booleans, integers, records and tuples use ordinary JSON atoms, objects and arrays. No JSON null: absent status/PC sentinel is `"none"`, absent request time is `-1` and empty verdict is `EmptyVerdict`.
- A TLA set is `{"__tla":"set","items":[...]}`. Empty set uses an empty items array. Set order is irrelevant.
- A function, especially with tuple keys, is `{"__tla":"function","entries":[{"key":...,"value":...},...]}`. Keys are native strings or identity tuples; duplicate keys are rejected. Empty function has no entries. Plain string-keyed objects are also valid function encodings when their domain is exactly correct.
- Nested sets/functions use these tags at the typed locations listed in the state mapping. `__tla` is reserved for these tags. `DecodeField` dispatches using the known state schema; it never applies scalar type tests to arbitrary JSON records and never substitutes missing fields.

`post` has exactly the **Required post fields** listed for that event below. Every value is the full current value of the named top-level `st` field. All listed fields are mandatory even if an EXCEPT branch leaves their value unchanged; extra captured post fields also fail. `ValidatePostState` checks exact domain equality and every value against `st'`. Do not omit a hard-to-capture field, remove a check, or supply the predicted next state to make a trace match.

### State capture and projection

| Fields | Actual observation or permitted recorder bookkeeping |
|---|---|
| `status`, `provisional`, `pending`, `allDone` | `_Ref.receiver_statuses`, `_pending_confirms` tuple status/presence, `_downloaded_to_all_called`, captured inside `_progress_lock` after the exact atomic mutation. Expand absent receiver entries to `none`/false. Never infer final status from progress. |
| `now`, `txLast`, `refLast`, `receiverLast`, `acquired`, `pullTime` | Controlled clock, `tx.last_active_time`, `ref._receiver_activity`, `tx._receiver_last_active`, `_acquired_receivers`, and local `now` captured at line 442. Keep the two lock publications distinct. All times use one integral test time unit with thresholds scaled consistently; do not replace times by event ranks. |
| `budgetLast`, `budgetNow`, `monitorNow`, `monitorPC` | Copy the actual stats snapshot and local monitor `now`; instrument admission, snapshot, candidate selection, freshness recheck, return and classification. A receiver's freshness test compares its timestamp, not the global clock. |
| `live`, `owner`, `closed`, `ops`, `terminating`, `settlementComplete`, `shutdown` | Table membership/identity, outcome-owner identity, `_ops_closed`, the recorder's operation-token set checked against `_active_ops`, termination marker and `_settlement_complete`; service shutdown checkpoint. Do not derive active operations from whether a client is still waiting. |
| `pullPC`, `futureStarted`, `tombstoneAt`, `index`, `rc`, `nonce`, `reply`, `replyNonce` | Checkpoints of each request plus actual future-start state, finished-ref retirement timestamp, request chunk state, produce RC and outgoing reply. A started future can survive cancellation before producer admission. Missing live refs can reply from a retained finished tombstone; shutdown clears it and the lookup checks its TTL. Nonce flags denote the matching nonce for this one no-retry terminal serve. Keep a raw nonce-to-pair binding in the recorder and check echoed equality; do not reduce an arbitrary received nonce to Boolean truthiness. |
| `consumer`, `consumerResult`, `consumerNonce`, `abandoned` | Actual Consumer entry/return/exception checkpoints, completion result and received terminal nonce. Failure bookkeeping reflects the actual exception/cancel path. Source EOF alone cannot set successful Consumer result. |
| `confirmWire`, `cancelWire` | Recorder ledger of actual send versus producer admission/drop. Capture control payload receiver, ref, status, nonce and routing identity; validate them against the pair ledger. Sets abstract a single supported confirmation per pair and one effective transaction cancellation per receiver; duplicate/retry traffic is outside this profile. |
| `fpc`, `fp`, `ftodo`, `fwon`, `faccepted`, `fall`, `finishReady` | Finalizer checkpoint, current ref/receiver, loop remainder, returned accepted/all_done values and pending finish-helper continuation. Initialize from actual loop inputs, advance only at recorded source boundaries. `fwon` is this call's winner; `faccepted` is the accumulated cancellation/budget result. |
| `progressStarted`, `progressOrder`, `progressTerminal`, `progressBytes`, `progressSeq`, `refTerminal` | `_receiver_progress` started/terminal flags, insertion order, bytes_done/sequence and `_terminal_progress_state`. The actual terminal state comes from the immutable event constructed when the terminal latch is set. Use a uniform ordinary one-byte DATA unit in the harness so each model byte increment is one; this profile omits item counters and throttling. |
| `pub`, `observedTerminal` | Thread-local desired progress call, constructed immutable event(s), callback entry/return checkpoint, and observer's delivered terminal notification. `pub.events` is a set of pending event records; delivery order is checked against the captured per-ref insertion order. Don't reconstruct delivered state from the latest shared receiver map. |
| `cause`, `queued`, `submitPC`, `spc` | Actual winning termination cause; executor queue publication/dequeue and submit return/exception; separate inline/worker settlement entry and continuation checkpoints. A RuntimeError after queue.put does not delete the queued token. Monitor/delete/shutdown settlement uses inline; only finish-helper submission uses worker. |
| `drainAt`, `drainForced`, `todo`, `snapshots`, `verdicts` | Each invocation's own drain-start clock, actual drain result, ordered loop remainder, copied per-ref receiver maps and actual computed/fallback TransferOutcome projection. Snapshot each ref under its lock; retain the local frozen copy across later status changes. |
| `baseObjects`, `sourceHeld` | Actual `base_objs` list elements, mapped by registration order to the original source object identities, and actual current registered `base_obj` reference under the source lock. Each invocation retains its own list. `sourceHeld=false` makes no claim about GC or application/future references. |
| `cb`, `objectDoneCalls`, `doneCalls`, `outcomeCbCalls`, `releaseAttempts`, `callbackErrors`, `effectsAfterReceipt` | Callback kind/ref and entry/running/return state, counted from actual hook entry; contained Exception count for modeled lifecycle hooks. After-receipt flag is set by observer order, never an invariant-derived value. Source release mutation is captured separately from hook return. |
| `receiptWrites`, `receipt`, `retained`, `recordAt`, `recordedBy` | Actual successful owner-guarded table insertion, projected stored outcome, retention membership and recording-time timestamp; identify the real recording invocation from instrumentation token. Ignored duplicate record calls must not increment writes. |
| `waiter`, `waiterOutcome`, `lateWaiter`, `lateOutcome` | Actual waiter registration, event resolution and outcome values. Pending None, terminal None and a non-None receipt are distinct. Second waiter starts unregistered. Keep already resolved values when service receipt retention expires. |
| `markerLeaked` | Actual local `_active_ops > 0` read at marker synchronization, preserved across subsequent acquisition of `_tx_lock`. |
| `caller` | Minimal `CellClientAPI._wait_for_result_transfers` result. A real non-None status other than COMPLETED yields error; progress callbacks are not its success signal. |

Verdict projection is `{status,reason,done,matrix,refsPresent,quorum}` from the actual `TransferOutcome`: done_status, complete per-ref receiver maps, nonempty refs flag and `quorum_met`. A computation-failed verdict has an empty actual refs tuple, represented by `refsPresent=false`, all-none matrix and quorum false. Timestamp is captured at actual recording in `recordAt`; header constants carry receiver/count/quorum metadata. Inspect callback args directly for outcome callbacks. Never recompute an implementation verdict with the model's `Verdict` and record that as observation.

## 2. Action-to-code mapping

Each row names one full base action and its sole event type (the event name is exactly the action name). Capture after the stated semantic mutation, before releasing its original lock; for user code, capture entry immediately before invocation and return/Exception immediately after it. Pure local/control checkpoints are recorded at the indicated branch/call boundary. The source reference covers the guards and changes in the corresponding base action; `action-map.json` is a machine-readable copy of this table.

| Action / event | Code location | Exact trigger | Args | Required post fields |
|---|---|---|---|---|
''']
for a in A:
    instrument.append('| `'+a['name']+'` | `'+a['source']+'` | '+a['trigger'].replace('|','\\|')+' | '+(', '.join('`'+n+'`' for n,d in a['params']) or 'empty object')+' | '+', '.join('`'+f+'`' for f in a['fields'])+' |\n')
instrument.append(r'''
## 3. Special considerations and handoff

**Capture order and locks.** Use a small recorder lock to order one semantic event and update a projection ledger. For original critical sections, capture changed fields while still holding the original lock; serialize the event before unlocking. For a single unlocked assignment, pair that assignment with its capture at that boundary. Do not take unrelated source locks to snapshot the entire transaction: copy the changed lock-owned slice and combine it with previously captured, unchanged entries in the ledger. Other entries are prior observations, not guessed model state. The ledger must not call the TLA next-state function or invent return values. Keep this recorder lock out of user callbacks, producer work, waits, executor submit acknowledgement, and all gaps between separately listed events. A harness lock spanning those gaps would suppress the target interleavings.

**Dispatch details.** `RefFinalizeReceiverCommit` instruments the whole `_progress_lock` section including duplicate/pending rejection. The callback gap starts only after that lock is released. Capture `RefObjServed` before the caller decides whether its returned nonce is present; capture terminal progress selection again at that later branch. An already-final receiver causes no pending resurrection. Ordinary progress construction suppresses a second terminal event; a suppressed event still needs its `RefMakeProgressEvent` record, with updated/suppressed counters as observed.

**Per-ref ordering.** The implementation iterates registered refs in list order. Capture it in the header and enforce it in all settlement/finalizer loops. `_receiver_progress` dictionary insertion order determines a batch terminal-progress callback order; capture it as `progressOrder`. Candidate receiver order within a ref is abstracted, but snapshot/recheck/dedup and ref ordering are retained. FINISHED checks are monotone scans over final statuses; log at the successful last check or the actual missing-ref check described in the coverage audit.

**Executor hook.** Instrument the actual `_work_queue.put(w)` boundary and `_adjust_thread_count()` acknowledgement/exception separately for the callback pool's selected settlement work item. Do not log enqueue only after `submit` returns. A local wrapper/proxy around the selected queue can capture put/dequeue without replacing its semantics; alternatively use an isolated copied stdlib executor for functional trace collection and disclose that boundary. Runtime fault reachability remains a separate local-regression obligation. Do not create resource exhaustion or modify production-wide executor behavior. A pre-enqueue stopped result is `CheckedExecutorSubmitStopped`; a queued work item followed by non-shutdown RuntimeError is `CheckedExecutorSubmitRuntimeError`. Preserve an already running/recovered worker's ability to run the queued item.

**Pipeline and failures.** Opt into supported value-stable `Consumer.supports_pipelining`; use ordinary uniform one-byte data and fixed payload shape. The next request launches before consume. A future not yet started can be cancelled; an admitted producer operation cannot be removed because consume failed. Keep that distinction in the actual executor/future observations. An ERROR terminal reply requests FAILED confirmation, whereas a PROCESS_EXCEPTION/MISSING_REF response follows the request-failure cancellation path. Do not fabricate a malformed Consumer state to trigger failure.

**Source and callback profile.** All modeled lifecycle callbacks are configured. Observe real user hook entry, actual argument identities, normal return and contained ordinary Exception. Release attempts are counted before user code; a successful owned-source release mutation and its return are separate. A custom source may raise before dropping its reference. Default no-op release, hook reentrancy/mutation of service internals, process BaseException and physical GC require other profiles. Progress callback normal return and contained Exception both use `TransactionProgressCallbackReturn`; no error counter or message for that distinction is captured in this model.

**Clock profile.** Use a controlled integral clock and explicit effective timeout settings. Production `OP_DRAIN_TIMEOUT` is 60 seconds; the small configs use abstract time units. Instrument/normalize a local regression with a consistent scale or use the actual value in the header. Do not independently compress timestamps and thresholds. `monitorNow` is the iteration's early time sample; snapshot and recheck use the actual stored request timestamp. A new pull between recheck and status commit does not cancel an already selected expiration by assumption.

**Observation levels.** Source terminal progress, receiver winning status, callback outcome, stored outcome and waited outcome are different observations. Record each at its own boundary. `outcome_cb` runs before releases. `RecordOutcome` is after this invocation's release attempts, while `Shutdown` can resolve pending waiters with None first. Retention expiry removes the service's receipt, not already-resolved waiter outcomes. Repeated request/retry sequences, re-registration, mixed peers and count-only receiver modes are explicitly outside this trace profile.

**Minimal callers and separate tests.** The main executable contract represents explicit receiver identities. Confirm actual `CellClientAPI` integration (`api.py:481-550,624-648`) or a direct ObjectDownloader caller configured equivalently. ViaDownloader registration (`via_downloader.py:774-826`) must finish before payload exposure. TV-1's multi-target fire-and-forget omits metadata (`cell.py:344-379`); test that separately with actual caller argument capture. TV-3's count-only matrices cannot be relabeled as explicit identities. `test_pass_through_e2e.py` mixes real Cells and a simulated hop; document the actual path exercised instead of treating its name as full transfer-barrier coverage. `TransferProgressTracker.update` advances last-progress time only on advancing counters or terminal events (`transfer_progress.py:199-223`); request activity in this model is independent.

**Suggested conformance corpus.** Collect normal two-receiver/two-ref confirmed success; receiver finalization failure; disjoint per-ref receiver success; sibling-ref idle expiry with another receiver active; never-acquired receiver expiry; confirmation/cancellation versus deletion; callback/release Exceptions; bounded drain with outstanding operation; shutdown before receipt; waiter before/after recording and retention expiry. Separately collect the supported pipeline cancellation and queue/acknowledgement interleavings if reachable in local functional fixtures. These are collection targets, not completed tests. First establish post-state conformance; only then run the hunt cfgs and classify counterexamples against source and local evidence.

`generate.py` regenerates the three modules/configs, four hunts, this mapping and `action-map.json`; `brief-coverage.md` is the manually read cfg/brief audit. After changing any action, regenerate, rerun artifact checks and update the audit. Do not edit generated Trace checks to accept a mismatching source observation.
''')
(P/'instrumentation-spec.md').write_text(''.join(instrument))
