------------------------------- MODULE Trace -------------------------------
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
RequiredFields(name) ==
    CASE name = "DownloadObjectStart" -> {"consumer", "futureStarted", "pullPC"}
      [] name = "HandleDownloadBegin" -> {"ops", "pullPC"}
      [] name = "HandleDownloadMissing" -> {"pullPC", "reply", "replyNonce"}
      [] name = "HandleDownloadMarkActive" -> {"pullPC", "txLast"}
      [] name = "RefMarkReceiverActive" -> {"pullPC", "pullTime", "refLast"}
      [] name = "TransactionMarkReceiverActive" -> {"acquired", "pullPC", "receiverLast"}
      [] name = "HandleDownloadActiveProgress" -> {"pub", "pullPC"}
      [] name = "HandleDownloadProduce" -> {"pullPC", "rc"}
      [] name = "HandleDownloadProduceException" -> {"pub", "pullPC", "rc"}
      [] name = "RefObjServed" -> {"nonce", "pending", "provisional", "pullPC"}
      [] name = "HandleDownloadTerminalProgress" -> {"pub", "pullPC"}
      [] name = "HandleDownloadDataProgress" -> {"nonce", "pub", "pullPC"}
      [] name = "HandleDownloadEndOp" -> {"ops", "pullPC", "reply", "replyNonce"}
      [] name = "ConsumerReceiveData" -> {"consumer", "index", "reply"}
      [] name = "ConsumerLaunchPipeline" -> {"consumer", "futureStarted", "pullPC"}
      [] name = "ConsumerConsumeReturn" -> {"consumer"}
      [] name = "ConsumerConsumeException" -> {"abandoned", "cancelWire", "consumer", "consumerResult", "pullPC"}
      [] name = "ConsumerReceiveEOF" -> {"consumer", "consumerNonce", "reply"}
      [] name = "ConsumerDownloadCompleted" -> {"consumer", "consumerResult"}
      [] name = "ConsumerDownloadCompletedException" -> {"consumer", "consumerResult"}
      [] name = "ConsumerSendConfirm" -> {"confirmWire", "consumer"}
      [] name = "ConsumerReceiveError" -> {"abandoned", "cancelWire", "consumer", "consumerResult", "reply"}
      [] name = "LoseConfirmation" -> {"confirmWire"}
      [] name = "HandleConfirmBegin" -> {"confirmWire", "fpc", "ftodo", "ops"}
      [] name = "HandleConfirmLate" -> {"confirmWire"}
      [] name = "HandleCancelBegin" -> {"cancelWire", "fpc", "ops"}
      [] name = "HandleCancelLate" -> {"cancelWire"}
      [] name = "HandleCancelAcquired" -> {"fpc", "ftodo"}
      [] name = "FinalizerSelectRef" -> {"fp", "fpc", "ftodo"}
      [] name = "RefFinalizeReceiverCommit" -> {"allDone", "cb", "faccepted", "fall", "fpc", "fwon", "pending", "provisional", "status"}
      [] name = "RefDownloadedToOneReturned" -> {"cb", "fpc"}
      [] name = "RefDownloadedToAllReturned" -> {"cb", "fpc"}
      [] name = "RefFinalizerProgress" -> {"fpc", "pub"}
      [] name = "FinalizerAdvance" -> {"fpc"}
      [] name = "HandleConfirmMarkActive" -> {"fpc", "txLast"}
      [] name = "HandleCancelLoopDone" -> {"fpc"}
      [] name = "FinalizerEndOp" -> {"finishReady", "fpc", "ops"}
      [] name = "MonitorBegin" -> {"monitorNow", "monitorPC"}
      [] name = "MonitorAdmitBudgets" -> {"fpc", "monitorPC", "ops"}
      [] name = "EnforceReceiverBudgetsSnapshot" -> {"budgetLast", "budgetNow", "faccepted", "fpc", "ftodo"}
      [] name = "RefEnforceBudgetSelect" -> {"fp", "fpc", "ftodo"}
      [] name = "RefEnforceBudgetRecheck" -> {"fpc"}
      [] name = "MonitorBudgetEndOp" -> {"fpc", "monitorPC", "ops"}
      [] name = "MonitorNoRetirement" -> {"monitorPC"}
      [] name = "FinishTransactionIfComplete" -> {"cause", "finishReady", "live", "submitPC", "terminating", "tombstoneAt"}
      [] name = "FinishTransactionNotComplete" -> {"finishReady"}
      [] name = "MonitorRetireFinished" -> {"cause", "live", "monitorPC", "spc", "terminating", "tombstoneAt"}
      [] name = "MonitorRetireTimeout" -> {"cause", "live", "monitorPC", "spc", "terminating"}
      [] name = "DeleteTransaction" -> {"cause", "live", "spc", "terminating"}
      [] name = "Shutdown" -> {"cause", "lateWaiter", "live", "owner", "retained", "shutdown", "spc", "terminating", "waiter"}
      [] name = "RefMakeProgressEvent" -> {"progressBytes", "progressOrder", "progressSeq", "progressStarted", "progressTerminal", "pub"}
      [] name = "TransactionEmitProgressEvent" -> {"observedTerminal", "pub"}
      [] name = "TransactionProgressCallbackReturn" -> {"pub"}
      [] name = "CheckedExecutorEnqueue" -> {"queued", "submitPC"}
      [] name = "CheckedExecutorSubmitReturn" -> {"submitPC"}
      [] name = "CheckedExecutorSubmitRuntimeError" -> {"submitPC"}
      [] name = "CheckedExecutorSubmitStopped" -> {"submitPC"}
      [] name = "SubmitFinishedSettlementFallback" -> {"spc", "submitPC"}
      [] name = "SettleFinishedTransactionWorker" -> {"queued", "spc"}
      [] name = "TransactionDoneDrainBegin" -> {"closed", "drainAt", "spc"}
      [] name = "TransactionDoneDrainEmpty" -> {"spc", "todo"}
      [] name = "TransactionDoneDrainExpired" -> {"drainForced", "spc", "todo"}
      [] name = "TransactionDoneSnapshotRef" -> {"snapshots", "todo"}
      [] name = "TransactionDoneComputeOutcome" -> {"spc", "todo", "verdicts"}
      [] name = "TransactionDoneComputeException" -> {"spc", "todo", "verdicts"}
      [] name = "TransactionDoneTerminalProgress" -> {"progressSeq", "progressTerminal", "pub", "refTerminal", "todo"}
      [] name = "TransactionDoneProgressReturned" -> {"spc", "todo"}
      [] name = "TransactionDoneSnapshotBaseObject" -> {"baseObjects", "todo"}
      [] name = "TransactionDoneObjectsBegin" -> {"spc", "todo"}
      [] name = "TransactionDoneObjectCallback" -> {"cb", "todo"}
      [] name = "TransactionDoneObjectReturned" -> {"cb"}
      [] name = "TransactionDoneTransactionCallback" -> {"cb", "spc"}
      [] name = "TransactionDoneOutcomeCallback" -> {"cb", "spc"}
      [] name = "TransactionDoneReleaseBegin" -> {"cb", "spc", "todo"}
      [] name = "TransactionDoneRelease" -> {"cb", "todo"}
      [] name = "TransactionDoneReleaseReturned" -> {"cb"}
      [] name = "InvokeCallbackSafely" -> {"cb", "doneCalls", "effectsAfterReceipt", "objectDoneCalls", "outcomeCbCalls", "releaseAttempts"}
      [] name = "ReleaseSourceReference" -> {"cb", "sourceHeld"}
      [] name = "CallbackReturn" -> {"cb"}
      [] name = "CallbackException" -> {"callbackErrors", "cb"}
      [] name = "TransactionDoneRecordReady" -> {"spc"}
      [] name = "RecordOutcome" -> {"lateOutcome", "lateWaiter", "owner", "receipt", "receiptWrites", "recordAt", "recordedBy", "retained", "spc", "waiter", "waiterOutcome"}
      [] name = "RecordOutcomeDrop" -> {"spc"}
      [] name = "TransactionDoneComplete" -> {"settlementComplete", "spc"}
      [] name = "SyncTerminationMarkerRead" -> {"markerLeaked", "spc"}
      [] name = "SyncTerminationMarkerWrite" -> {"spc", "terminating"}
      [] name = "ReapTerminationMarker" -> {"terminating"}
      [] name = "ExpireOutcome" -> {"retained"}
      [] name = "GetTransferWaiter" -> {"lateOutcome", "lateWaiter"}
      [] name = "WaitForResultTransfers" -> {"caller"}
      [] name = "AdvanceTime" -> {"now"}
      [] name = "HandleDownloadProduceError" -> {"pullPC", "rc"}
      [] name = "ConsumerReceiveProducerError" -> {"consumer", "consumerNonce", "consumerResult", "reply"}
      [] name = "DownloadRequestWorkerStart" -> {"futureStarted"}
      [] OTHER -> {}

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

\* download_service.py:2164-2182,2203-2209: same complete base action and mandatory observed post-state.
TraceDownloadObjectStart ==
    LET p == logline.args.p
    IN
    /\ IsEvent("DownloadObjectStart", {"p"})
    /\ p \in Pairs
    /\ DownloadObjectStart(p)
    /\ ValidatePostState("DownloadObjectStart")
    /\ l' = l + 1

\* download_service.py:1681-1699,822-833: same complete base action and mandatory observed post-state.
TraceHandleDownloadBegin ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadBegin", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadBegin(p)
    /\ ValidatePostState("HandleDownloadBegin")
    /\ l' = l + 1

\* download_service.py:1681-1697: same complete base action and mandatory observed post-state.
TraceHandleDownloadMissing ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadMissing", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadMissing(p)
    /\ ValidatePostState("HandleDownloadMissing")
    /\ l' = l + 1

\* download_service.py:1701,300-301,774-775: same complete base action and mandatory observed post-state.
TraceHandleDownloadMarkActive ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadMarkActive", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadMarkActive(p)
    /\ ValidatePostState("HandleDownloadMarkActive")
    /\ l' = l + 1

\* download_service.py:441-444,1702: same complete base action and mandatory observed post-state.
TraceRefMarkReceiverActive ==
    LET p == logline.args.p
    IN
    /\ IsEvent("RefMarkReceiverActive", {"p"})
    /\ p \in Pairs
    /\ RefMarkReceiverActive(p)
    /\ ValidatePostState("RefMarkReceiverActive")
    /\ l' = l + 1

\* download_service.py:445-450: same complete base action and mandatory observed post-state.
TraceTransactionMarkReceiverActive ==
    LET p == logline.args.p
    IN
    /\ IsEvent("TransactionMarkReceiverActive", {"p"})
    /\ p \in Pairs
    /\ TransactionMarkReceiverActive(p)
    /\ ValidatePostState("TransactionMarkReceiverActive")
    /\ l' = l + 1

\* download_service.py:1703,517-542: same complete base action and mandatory observed post-state.
TraceHandleDownloadActiveProgress ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadActiveProgress", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadActiveProgress(p)
    /\ ValidatePostState("HandleDownloadActiveProgress")
    /\ l' = l + 1

\* download_service.py:1707-1716,1724,1751-1775: same complete base action and mandatory observed post-state.
TraceHandleDownloadProduce ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadProduce", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadProduce(p)
    /\ ValidatePostState("HandleDownloadProduce")
    /\ l' = l + 1

\* download_service.py:1715-1722: same complete base action and mandatory observed post-state.
TraceHandleDownloadProduceException ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadProduceException", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadProduceException(p)
    /\ ValidatePostState("HandleDownloadProduceException")
    /\ l' = l + 1

\* download_service.py:369-397,1728-1732: same complete base action and mandatory observed post-state.
TraceRefObjServed ==
    LET p == logline.args.p
    IN
    /\ IsEvent("RefObjServed", {"p"})
    /\ p \in Pairs
    /\ RefObjServed(p)
    /\ ValidatePostState("RefObjServed")
    /\ l' = l + 1

\* download_service.py:1733-1749: same complete base action and mandatory observed post-state.
TraceHandleDownloadTerminalProgress ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadTerminalProgress", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadTerminalProgress(p)
    /\ ValidatePostState("HandleDownloadTerminalProgress")
    /\ l' = l + 1

\* download_service.py:1752-1775: same complete base action and mandatory observed post-state.
TraceHandleDownloadDataProgress ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadDataProgress", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadDataProgress(p)
    /\ ValidatePostState("HandleDownloadDataProgress")
    /\ l' = l + 1

\* download_service.py:1750,1768-1779,835-839: same complete base action and mandatory observed post-state.
TraceHandleDownloadEndOp ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadEndOp", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadEndOp(p)
    /\ ValidatePostState("HandleDownloadEndOp")
    /\ l' = l + 1

\* download_service.py:2212-2213,2291-2298: same complete base action and mandatory observed post-state.
TraceConsumerReceiveData ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerReceiveData", {"p"})
    /\ p \in Pairs
    /\ ConsumerReceiveData(p)
    /\ ValidatePostState("ConsumerReceiveData")
    /\ l' = l + 1

\* download_service.py:2300-2305: same complete base action and mandatory observed post-state.
TraceConsumerLaunchPipeline ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerLaunchPipeline", {"p"})
    /\ p \in Pairs
    /\ ConsumerLaunchPipeline(p)
    /\ ValidatePostState("ConsumerLaunchPipeline")
    /\ l' = l + 1

\* download_service.py:2309-2310,2333-2349: same complete base action and mandatory observed post-state.
TraceConsumerConsumeReturn ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerConsumeReturn", {"p"})
    /\ p \in Pairs
    /\ ConsumerConsumeReturn(p)
    /\ ValidatePostState("ConsumerConsumeReturn")
    /\ l' = l + 1

\* download_service.py:2311-2317: same complete base action and mandatory observed post-state.
TraceConsumerConsumeException ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerConsumeException", {"p"})
    /\ p \in Pairs
    /\ ConsumerConsumeException(p)
    /\ ValidatePostState("ConsumerConsumeException")
    /\ l' = l + 1

\* download_service.py:2260-2274: same complete base action and mandatory observed post-state.
TraceConsumerReceiveEOF ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerReceiveEOF", {"p"})
    /\ p \in Pairs
    /\ ConsumerReceiveEOF(p)
    /\ ValidatePostState("ConsumerReceiveEOF")
    /\ l' = l + 1

\* download_service.py:2273-2283: same complete base action and mandatory observed post-state.
TraceConsumerDownloadCompleted ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerDownloadCompleted", {"p"})
    /\ p \in Pairs
    /\ ConsumerDownloadCompleted(p)
    /\ ValidatePostState("ConsumerDownloadCompleted")
    /\ l' = l + 1

\* download_service.py:2273-2281: same complete base action and mandatory observed post-state.
TraceConsumerDownloadCompletedException ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerDownloadCompletedException", {"p"})
    /\ p \in Pairs
    /\ ConsumerDownloadCompletedException(p)
    /\ ValidatePostState("ConsumerDownloadCompletedException")
    /\ l' = l + 1

\* download_service.py:2083-2105,2279-2283: same complete base action and mandatory observed post-state.
TraceConsumerSendConfirm ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerSendConfirm", {"p"})
    /\ p \in Pairs
    /\ ConsumerSendConfirm(p)
    /\ ValidatePostState("ConsumerSendConfirm")
    /\ l' = l + 1

\* download_service.py:2221-2250: same complete base action and mandatory observed post-state.
TraceConsumerReceiveError ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerReceiveError", {"p"})
    /\ p \in Pairs
    /\ ConsumerReceiveError(p)
    /\ ValidatePostState("ConsumerReceiveError")
    /\ l' = l + 1

\* download_service.py:2083-2105,456-469: same complete base action and mandatory observed post-state.
TraceLoseConfirmation ==
    LET p == logline.args.p
    IN
    /\ IsEvent("LoseConfirmation", {"p"})
    /\ p \in Pairs
    /\ LoseConfirmation(p)
    /\ ValidatePostState("LoseConfirmation")
    /\ l' = l + 1

\* download_service.py:1782-1799,822-833: same complete base action and mandatory observed post-state.
TraceHandleConfirmBegin ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleConfirmBegin", {"p"})
    /\ p \in Pairs
    /\ HandleConfirmBegin(p)
    /\ ValidatePostState("HandleConfirmBegin")
    /\ l' = l + 1

\* download_service.py:1783-1793: same complete base action and mandatory observed post-state.
TraceHandleConfirmLate ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleConfirmLate", {"p"})
    /\ p \in Pairs
    /\ HandleConfirmLate(p)
    /\ ValidatePostState("HandleConfirmLate")
    /\ l' = l + 1

\* download_service.py:1814-1827,822-833: same complete base action and mandatory observed post-state.
TraceHandleCancelBegin ==
    LET c == logline.args.c
    IN
    /\ IsEvent("HandleCancelBegin", {"c"})
    /\ c \in Receivers
    /\ HandleCancelBegin(c)
    /\ ValidatePostState("HandleCancelBegin")
    /\ l' = l + 1

\* download_service.py:1816-1822: same complete base action and mandatory observed post-state.
TraceHandleCancelLate ==
    LET c == logline.args.c
    IN
    /\ IsEvent("HandleCancelLate", {"c"})
    /\ c \in Receivers
    /\ HandleCancelLate(c)
    /\ ValidatePostState("HandleCancelLate")
    /\ l' = l + 1

\* download_service.py:1828-1839: same complete base action and mandatory observed post-state.
TraceHandleCancelAcquired ==
    LET c == logline.args.c
    IN
    /\ IsEvent("HandleCancelAcquired", {"c"})
    /\ c \in Receivers
    /\ HandleCancelAcquired(c)
    /\ ValidatePostState("HandleCancelAcquired")
    /\ l' = l + 1

\* download_service.py:1799,1838-1839,306-308: same complete base action and mandatory observed post-state.
TraceFinalizerSelectRef ==
    LET t == logline.args.t
        p == logline.args.p
    IN
    /\ IsEvent("FinalizerSelectRef", {"t", "p"})
    /\ t \in Confirmers \cup Cancellers
    /\ p \in Pairs
    /\ FinalizerSelectRef(t, p)
    /\ ValidatePostState("FinalizerSelectRef")
    /\ l' = l + 1

\* download_service.py:313-335: same complete base action and mandatory observed post-state.
TraceRefFinalizeReceiverCommit ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RefFinalizeReceiverCommit", {"t"})
    /\ t \in Finalizers
    /\ RefFinalizeReceiverCommit(t)
    /\ ValidatePostState("RefFinalizeReceiverCommit")
    /\ l' = l + 1

\* download_service.py:342-357: same complete base action and mandatory observed post-state.
TraceRefDownloadedToOneReturned ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RefDownloadedToOneReturned", {"t"})
    /\ t \in Finalizers
    /\ RefDownloadedToOneReturned(t)
    /\ ValidatePostState("RefDownloadedToOneReturned")
    /\ l' = l + 1

\* download_service.py:350-357: same complete base action and mandatory observed post-state.
TraceRefDownloadedToAllReturned ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RefDownloadedToAllReturned", {"t"})
    /\ t \in Finalizers
    /\ RefDownloadedToAllReturned(t)
    /\ ValidatePostState("RefDownloadedToAllReturned")
    /\ l' = l + 1

\* download_service.py:411-429,510-514: same complete base action and mandatory observed post-state.
TraceRefFinalizerProgress ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RefFinalizerProgress", {"t"})
    /\ t \in Finalizers
    /\ RefFinalizerProgress(t)
    /\ ValidatePostState("RefFinalizerProgress")
    /\ l' = l + 1

\* download_service.py:423-430,504-515,1799-1801,1838-1839: same complete base action and mandatory observed post-state.
TraceFinalizerAdvance ==
    LET t == logline.args.t
    IN
    /\ IsEvent("FinalizerAdvance", {"t"})
    /\ t \in Finalizers
    /\ FinalizerAdvance(t)
    /\ ValidatePostState("FinalizerAdvance")
    /\ l' = l + 1

\* download_service.py:1799-1803: same complete base action and mandatory observed post-state.
TraceHandleConfirmMarkActive ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleConfirmMarkActive", {"p"})
    /\ p \in Pairs
    /\ HandleConfirmMarkActive(p)
    /\ ValidatePostState("HandleConfirmMarkActive")
    /\ l' = l + 1

\* download_service.py:1838-1841: same complete base action and mandatory observed post-state.
TraceHandleCancelLoopDone ==
    LET c == logline.args.c
    IN
    /\ IsEvent("HandleCancelLoopDone", {"c"})
    /\ c \in Receivers
    /\ HandleCancelLoopDone(c)
    /\ ValidatePostState("HandleCancelLoopDone")
    /\ l' = l + 1

\* download_service.py:1802-1810,1840-1844,835-839: same complete base action and mandatory observed post-state.
TraceFinalizerEndOp ==
    LET t == logline.args.t
    IN
    /\ IsEvent("FinalizerEndOp", {"t"})
    /\ t \in Confirmers \cup Cancellers
    /\ FinalizerEndOp(t)
    /\ ValidatePostState("FinalizerEndOp")
    /\ l' = l + 1

\* download_service.py:1848-1863: same complete base action and mandatory observed post-state.
TraceMonitorBegin ==
    /\ IsEvent("MonitorBegin", {})
    /\ MonitorBegin
    /\ ValidatePostState("MonitorBegin")
    /\ l' = l + 1

\* download_service.py:1856-1865,822-833: same complete base action and mandatory observed post-state.
TraceMonitorAdmitBudgets ==
    /\ IsEvent("MonitorAdmitBudgets", {})
    /\ MonitorAdmitBudgets
    /\ ValidatePostState("MonitorAdmitBudgets")
    /\ l' = l + 1

\* download_service.py:857-873: same complete base action and mandatory observed post-state.
TraceEnforceReceiverBudgetsSnapshot ==
    /\ IsEvent("EnforceReceiverBudgetsSnapshot", {})
    /\ EnforceReceiverBudgetsSnapshot
    /\ ValidatePostState("EnforceReceiverBudgetsSnapshot")
    /\ l' = l + 1

\* download_service.py:475-502: same complete base action and mandatory observed post-state.
TraceRefEnforceBudgetSelect ==
    LET p == logline.args.p
    IN
    /\ IsEvent("RefEnforceBudgetSelect", {"p"})
    /\ p \in Pairs
    /\ RefEnforceBudgetSelect(p)
    /\ ValidatePostState("RefEnforceBudgetSelect")
    /\ l' = l + 1

\* download_service.py:504-510: same complete base action and mandatory observed post-state.
TraceRefEnforceBudgetRecheck ==
    /\ IsEvent("RefEnforceBudgetRecheck", {})
    /\ RefEnforceBudgetRecheck
    /\ ValidatePostState("RefEnforceBudgetRecheck")
    /\ l' = l + 1

\* download_service.py:1864-1871,835-839: same complete base action and mandatory observed post-state.
TraceMonitorBudgetEndOp ==
    /\ IsEvent("MonitorBudgetEndOp", {})
    /\ MonitorBudgetEndOp
    /\ ValidatePostState("MonitorBudgetEndOp")
    /\ l' = l + 1

\* download_service.py:1875-1890,1909: same complete base action and mandatory observed post-state.
TraceMonitorNoRetirement ==
    /\ IsEvent("MonitorNoRetirement", {})
    /\ MonitorNoRetirement
    /\ ValidatePostState("MonitorNoRetirement")
    /\ l' = l + 1

\* download_service.py:1411-1425,1525-1541: same complete base action and mandatory observed post-state.
TraceFinishTransactionIfComplete ==
    LET t == logline.args.t
    IN
    /\ IsEvent("FinishTransactionIfComplete", {"t"})
    /\ t \in Confirmers \cup Cancellers
    /\ FinishTransactionIfComplete(t)
    /\ ValidatePostState("FinishTransactionIfComplete")
    /\ l' = l + 1

\* download_service.py:1420-1422: same complete base action and mandatory observed post-state.
TraceFinishTransactionNotComplete ==
    LET t == logline.args.t
    IN
    /\ IsEvent("FinishTransactionNotComplete", {"t"})
    /\ t \in Confirmers \cup Cancellers
    /\ FinishTransactionNotComplete(t)
    /\ ValidatePostState("FinishTransactionNotComplete")
    /\ l' = l + 1

\* download_service.py:1875-1890,1903-1907: same complete base action and mandatory observed post-state.
TraceMonitorRetireFinished ==
    /\ IsEvent("MonitorRetireFinished", {})
    /\ MonitorRetireFinished
    /\ ValidatePostState("MonitorRetireFinished")
    /\ l' = l + 1

\* download_service.py:1880-1887,1897-1901: same complete base action and mandatory observed post-state.
TraceMonitorRetireTimeout ==
    /\ IsEvent("MonitorRetireTimeout", {})
    /\ MonitorRetireTimeout
    /\ ValidatePostState("MonitorRetireTimeout")
    /\ l' = l + 1

\* download_service.py:1399-1408,1525-1541: same complete base action and mandatory observed post-state.
TraceDeleteTransaction ==
    /\ IsEvent("DeleteTransaction", {})
    /\ DeleteTransaction
    /\ ValidatePostState("DeleteTransaction")
    /\ l' = l + 1

\* download_service.py:1457-1497: same complete base action and mandatory observed post-state.
TraceShutdown ==
    /\ IsEvent("Shutdown", {})
    /\ Shutdown
    /\ ValidatePostState("Shutdown")
    /\ l' = l + 1

\* download_service.py:526-612: same complete base action and mandatory observed post-state.
TraceRefMakeProgressEvent ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RefMakeProgressEvent", {"t"})
    /\ t \in Actors
    /\ RefMakeProgressEvent(t)
    /\ ValidatePostState("RefMakeProgressEvent")
    /\ l' = l + 1

\* download_service.py:539-542,1004-1013: same complete base action and mandatory observed post-state.
TraceTransactionEmitProgressEvent ==
    LET t == logline.args.t
        e == logline.args.e
    IN
    /\ IsEvent("TransactionEmitProgressEvent", {"t", "e"})
    /\ t \in Actors
    /\ e \in st.pub[t].events
    /\ TransactionEmitProgressEvent(t, e)
    /\ ValidatePostState("TransactionEmitProgressEvent")
    /\ l' = l + 1

\* download_service.py:1008-1013: same complete base action and mandatory observed post-state.
TraceTransactionProgressCallbackReturn ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionProgressCallbackReturn", {"t"})
    /\ t \in Actors
    /\ TransactionProgressCallbackReturn(t)
    /\ ValidatePostState("TransactionProgressCallbackReturn")
    /\ l' = l + 1

\* stream_utils.py:60-78; concurrent/futures/thread.py:199-216: same complete base action and mandatory observed post-state.
TraceCheckedExecutorEnqueue ==
    /\ IsEvent("CheckedExecutorEnqueue", {})
    /\ CheckedExecutorEnqueue
    /\ ValidatePostState("CheckedExecutorEnqueue")
    /\ l' = l + 1

\* stream_utils.py:65-66; concurrent/futures/thread.py:199-216: same complete base action and mandatory observed post-state.
TraceCheckedExecutorSubmitReturn ==
    /\ IsEvent("CheckedExecutorSubmitReturn", {})
    /\ CheckedExecutorSubmitReturn
    /\ ValidatePostState("CheckedExecutorSubmitReturn")
    /\ l' = l + 1

\* stream_utils.py:71-78; download_service.py:1435-1441: same complete base action and mandatory observed post-state.
TraceCheckedExecutorSubmitRuntimeError ==
    /\ IsEvent("CheckedExecutorSubmitRuntimeError", {})
    /\ CheckedExecutorSubmitRuntimeError
    /\ ValidatePostState("CheckedExecutorSubmitRuntimeError")
    /\ l' = l + 1

\* stream_utils.py:61-64,79-81; download_service.py:1442-1446: same complete base action and mandatory observed post-state.
TraceCheckedExecutorSubmitStopped ==
    /\ IsEvent("CheckedExecutorSubmitStopped", {})
    /\ CheckedExecutorSubmitStopped
    /\ ValidatePostState("CheckedExecutorSubmitStopped")
    /\ l' = l + 1

\* download_service.py:1442-1454: same complete base action and mandatory observed post-state.
TraceSubmitFinishedSettlementFallback ==
    /\ IsEvent("SubmitFinishedSettlementFallback", {})
    /\ SubmitFinishedSettlementFallback
    /\ ValidatePostState("SubmitFinishedSettlementFallback")
    /\ l' = l + 1

\* stream_utils.py:65-78,84-85; download_service.py:1449-1454: same complete base action and mandatory observed post-state.
TraceSettleFinishedTransactionWorker ==
    /\ IsEvent("SettleFinishedTransactionWorker", {})
    /\ SettleFinishedTransactionWorker
    /\ ValidatePostState("SettleFinishedTransactionWorker")
    /\ l' = l + 1

\* download_service.py:895-906,841-850: same complete base action and mandatory observed post-state.
TraceTransactionDoneDrainBegin ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneDrainBegin", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneDrainBegin(t)
    /\ ValidatePostState("TransactionDoneDrainBegin")
    /\ l' = l + 1

\* download_service.py:841-851,910: same complete base action and mandatory observed post-state.
TraceTransactionDoneDrainEmpty ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneDrainEmpty", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneDrainEmpty(t)
    /\ ValidatePostState("TransactionDoneDrainEmpty")
    /\ l' = l + 1

\* download_service.py:846-849,905-910: same complete base action and mandatory observed post-state.
TraceTransactionDoneDrainExpired ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneDrainExpired", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneDrainExpired(t)
    /\ ValidatePostState("TransactionDoneDrainExpired")
    /\ l' = l + 1

\* download_service.py:910,918-927,432-434: same complete base action and mandatory observed post-state.
TraceTransactionDoneSnapshotRef ==
    LET t == logline.args.t
        r == logline.args.r
    IN
    /\ IsEvent("TransactionDoneSnapshotRef", {"t", "r"})
    /\ t \in Settlers
    /\ r \in Refs
    /\ TransactionDoneSnapshotRef(t, r)
    /\ ValidatePostState("TransactionDoneSnapshotRef")
    /\ l' = l + 1

\* download_service.py:918-928; transfer_outcome.py:156-202,242-271: same complete base action and mandatory observed post-state.
TraceTransactionDoneComputeOutcome ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneComputeOutcome", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneComputeOutcome(t)
    /\ ValidatePostState("TransactionDoneComputeOutcome")
    /\ l' = l + 1

\* download_service.py:929-933,803-820: same complete base action and mandatory observed post-state.
TraceTransactionDoneComputeException ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneComputeException", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneComputeException(t)
    /\ ValidatePostState("TransactionDoneComputeException")
    /\ l' = l + 1

\* download_service.py:935-938,544-564,576-612: same complete base action and mandatory observed post-state.
TraceTransactionDoneTerminalProgress ==
    LET t == logline.args.t
        r == logline.args.r
    IN
    /\ IsEvent("TransactionDoneTerminalProgress", {"t", "r"})
    /\ t \in Settlers
    /\ r \in Refs
    /\ TransactionDoneTerminalProgress(t, r)
    /\ ValidatePostState("TransactionDoneTerminalProgress")
    /\ l' = l + 1

\* download_service.py:935-953: same complete base action and mandatory observed post-state.
TraceTransactionDoneProgressReturned ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneProgressReturned", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneProgressReturned(t)
    /\ ValidatePostState("TransactionDoneProgressReturned")
    /\ l' = l + 1

\* download_service.py:948-953: same complete base action and mandatory observed post-state.
TraceTransactionDoneSnapshotBaseObject ==
    LET t == logline.args.t
        r == logline.args.r
    IN
    /\ IsEvent("TransactionDoneSnapshotBaseObject", {"t", "r"})
    /\ t \in Settlers
    /\ r \in Refs
    /\ TransactionDoneSnapshotBaseObject(t, r)
    /\ ValidatePostState("TransactionDoneSnapshotBaseObject")
    /\ l' = l + 1

\* download_service.py:953-955: same complete base action and mandatory observed post-state.
TraceTransactionDoneObjectsBegin ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneObjectsBegin", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneObjectsBegin(t)
    /\ ValidatePostState("TransactionDoneObjectsBegin")
    /\ l' = l + 1

\* download_service.py:955-964: same complete base action and mandatory observed post-state.
TraceTransactionDoneObjectCallback ==
    LET t == logline.args.t
        r == logline.args.r
    IN
    /\ IsEvent("TransactionDoneObjectCallback", {"t", "r"})
    /\ t \in Settlers
    /\ r \in Refs
    /\ TransactionDoneObjectCallback(t, r)
    /\ ValidatePostState("TransactionDoneObjectCallback")
    /\ l' = l + 1

\* download_service.py:955-964: same complete base action and mandatory observed post-state.
TraceTransactionDoneObjectReturned ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneObjectReturned", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneObjectReturned(t)
    /\ ValidatePostState("TransactionDoneObjectReturned")
    /\ l' = l + 1

\* download_service.py:966-975: same complete base action and mandatory observed post-state.
TraceTransactionDoneTransactionCallback ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneTransactionCallback", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneTransactionCallback(t)
    /\ ValidatePostState("TransactionDoneTransactionCallback")
    /\ l' = l + 1

\* download_service.py:977-978: same complete base action and mandatory observed post-state.
TraceTransactionDoneOutcomeCallback ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneOutcomeCallback", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneOutcomeCallback(t)
    /\ ValidatePostState("TransactionDoneOutcomeCallback")
    /\ l' = l + 1

\* download_service.py:977-989: same complete base action and mandatory observed post-state.
TraceTransactionDoneReleaseBegin ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneReleaseBegin", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneReleaseBegin(t)
    /\ ValidatePostState("TransactionDoneReleaseBegin")
    /\ l' = l + 1

\* download_service.py:985-989: same complete base action and mandatory observed post-state.
TraceTransactionDoneRelease ==
    LET t == logline.args.t
        r == logline.args.r
    IN
    /\ IsEvent("TransactionDoneRelease", {"t", "r"})
    /\ t \in Settlers
    /\ r \in Refs
    /\ TransactionDoneRelease(t, r)
    /\ ValidatePostState("TransactionDoneRelease")
    /\ l' = l + 1

\* download_service.py:988-989: same complete base action and mandatory observed post-state.
TraceTransactionDoneReleaseReturned ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneReleaseReturned", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneReleaseReturned(t)
    /\ ValidatePostState("TransactionDoneReleaseReturned")
    /\ l' = l + 1

\* download_service.py:645-655,342-356,958-989: same complete base action and mandatory observed post-state.
TraceInvokeCallbackSafely ==
    LET t == logline.args.t
        arg == DecodeCallbackArg(t, logline.args.arg)
    IN
    /\ IsEvent("InvokeCallbackSafely", {"t", "arg"})
    /\ t \in Actors
    /\ arg \in {CallbackArgs(t)}
    /\ InvokeCallbackSafely(t, arg)
    /\ ValidatePostState("InvokeCallbackSafely")
    /\ l' = l + 1

\* cacheable.py:109-120; download_service.py:193-201,988-989: same complete base action and mandatory observed post-state.
TraceReleaseSourceReference ==
    LET t == logline.args.t
    IN
    /\ IsEvent("ReleaseSourceReference", {"t"})
    /\ t \in Settlers
    /\ ReleaseSourceReference(t)
    /\ ValidatePostState("ReleaseSourceReference")
    /\ l' = l + 1

\* download_service.py:645-655: same complete base action and mandatory observed post-state.
TraceCallbackReturn ==
    LET t == logline.args.t
    IN
    /\ IsEvent("CallbackReturn", {"t"})
    /\ t \in Actors
    /\ CallbackReturn(t)
    /\ ValidatePostState("CallbackReturn")
    /\ l' = l + 1

\* download_service.py:645-655,985-989: same complete base action and mandatory observed post-state.
TraceCallbackException ==
    LET t == logline.args.t
    IN
    /\ IsEvent("CallbackException", {"t"})
    /\ t \in Actors
    /\ CallbackException(t)
    /\ ValidatePostState("CallbackException")
    /\ l' = l + 1

\* download_service.py:988-999: same complete base action and mandatory observed post-state.
TraceTransactionDoneRecordReady ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneRecordReady", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneRecordReady(t)
    /\ ValidatePostState("TransactionDoneRecordReady")
    /\ l' = l + 1

\* download_service.py:1579-1595,998-1000: same complete base action and mandatory observed post-state.
TraceRecordOutcome ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RecordOutcome", {"t"})
    /\ t \in Settlers
    /\ RecordOutcome(t)
    /\ ValidatePostState("RecordOutcome")
    /\ l' = l + 1

\* download_service.py:1582-1585,998-1000: same complete base action and mandatory observed post-state.
TraceRecordOutcomeDrop ==
    LET t == logline.args.t
    IN
    /\ IsEvent("RecordOutcomeDrop", {"t"})
    /\ t \in Settlers
    /\ RecordOutcomeDrop(t)
    /\ ValidatePostState("RecordOutcomeDrop")
    /\ l' = l + 1

\* download_service.py:1000-1002: same complete base action and mandatory observed post-state.
TraceTransactionDoneComplete ==
    LET t == logline.args.t
    IN
    /\ IsEvent("TransactionDoneComplete", {"t"})
    /\ t \in Settlers
    /\ TransactionDoneComplete(t)
    /\ ValidatePostState("TransactionDoneComplete")
    /\ l' = l + 1

\* download_service.py:1500-1505: same complete base action and mandatory observed post-state.
TraceSyncTerminationMarkerRead ==
    LET t == logline.args.t
    IN
    /\ IsEvent("SyncTerminationMarkerRead", {"t"})
    /\ t \in Settlers
    /\ SyncTerminationMarkerRead(t)
    /\ ValidatePostState("SyncTerminationMarkerRead")
    /\ l' = l + 1

\* download_service.py:1506-1510: same complete base action and mandatory observed post-state.
TraceSyncTerminationMarkerWrite ==
    LET t == logline.args.t
    IN
    /\ IsEvent("SyncTerminationMarkerWrite", {"t"})
    /\ t \in Settlers
    /\ SyncTerminationMarkerWrite(t)
    /\ ValidatePostState("SyncTerminationMarkerWrite")
    /\ l' = l + 1

\* download_service.py:1513-1522: same complete base action and mandatory observed post-state.
TraceReapTerminationMarker ==
    /\ IsEvent("ReapTerminationMarker", {})
    /\ ReapTerminationMarker
    /\ ValidatePostState("ReapTerminationMarker")
    /\ l' = l + 1

\* download_service.py:1611-1619; transfer_outcome.py:181-182: same complete base action and mandatory observed post-state.
TraceExpireOutcome ==
    /\ IsEvent("ExpireOutcome", {})
    /\ ExpireOutcome
    /\ ValidatePostState("ExpireOutcome")
    /\ l' = l + 1

\* download_service.py:1544-1565: same complete base action and mandatory observed post-state.
TraceGetTransferWaiter ==
    /\ IsEvent("GetTransferWaiter", {})
    /\ GetTransferWaiter
    /\ ValidatePostState("GetTransferWaiter")
    /\ l' = l + 1

\* nvflare/client/cell/api.py:624-648: same complete base action and mandatory observed post-state.
TraceWaitForResultTransfers ==
    /\ IsEvent("WaitForResultTransfers", {})
    /\ WaitForResultTransfers
    /\ ValidatePostState("WaitForResultTransfers")
    /\ l' = l + 1

\* download_service.py:441-442,774-775,843-849,1850,1909: same complete base action and mandatory observed post-state.
TraceAdvanceTime ==
    /\ IsEvent("AdvanceTime", {})
    /\ AdvanceTime
    /\ ValidatePostState("AdvanceTime")
    /\ l' = l + 1

\* download_service.py:1716,1724-1732: same complete base action and mandatory observed post-state.
TraceHandleDownloadProduceError ==
    LET p == logline.args.p
    IN
    /\ IsEvent("HandleDownloadProduceError", {"p"})
    /\ p \in Pairs
    /\ HandleDownloadProduceError(p)
    /\ ValidatePostState("HandleDownloadProduceError")
    /\ l' = l + 1

\* download_service.py:2260-2265,2285-2289: same complete base action and mandatory observed post-state.
TraceConsumerReceiveProducerError ==
    LET p == logline.args.p
    IN
    /\ IsEvent("ConsumerReceiveProducerError", {"p"})
    /\ p \in Pairs
    /\ ConsumerReceiveProducerError(p)
    /\ ValidatePostState("ConsumerReceiveProducerError")
    /\ l' = l + 1

\* download_service.py:2166-2182,2300-2305,2312-2313: same complete base action and mandatory observed post-state.
TraceDownloadRequestWorkerStart ==
    LET p == logline.args.p
    IN
    /\ IsEvent("DownloadRequestWorkerStart", {"p"})
    /\ p \in Pairs
    /\ DownloadRequestWorkerStart(p)
    /\ ValidatePostState("DownloadRequestWorkerStart")
    /\ l' = l + 1

TraceStep ==
    \/ TraceDownloadObjectStart
    \/ TraceHandleDownloadBegin
    \/ TraceHandleDownloadMissing
    \/ TraceHandleDownloadMarkActive
    \/ TraceRefMarkReceiverActive
    \/ TraceTransactionMarkReceiverActive
    \/ TraceHandleDownloadActiveProgress
    \/ TraceHandleDownloadProduce
    \/ TraceHandleDownloadProduceException
    \/ TraceRefObjServed
    \/ TraceHandleDownloadTerminalProgress
    \/ TraceHandleDownloadDataProgress
    \/ TraceHandleDownloadEndOp
    \/ TraceConsumerReceiveData
    \/ TraceConsumerLaunchPipeline
    \/ TraceConsumerConsumeReturn
    \/ TraceConsumerConsumeException
    \/ TraceConsumerReceiveEOF
    \/ TraceConsumerDownloadCompleted
    \/ TraceConsumerDownloadCompletedException
    \/ TraceConsumerSendConfirm
    \/ TraceConsumerReceiveError
    \/ TraceLoseConfirmation
    \/ TraceHandleConfirmBegin
    \/ TraceHandleConfirmLate
    \/ TraceHandleCancelBegin
    \/ TraceHandleCancelLate
    \/ TraceHandleCancelAcquired
    \/ TraceFinalizerSelectRef
    \/ TraceRefFinalizeReceiverCommit
    \/ TraceRefDownloadedToOneReturned
    \/ TraceRefDownloadedToAllReturned
    \/ TraceRefFinalizerProgress
    \/ TraceFinalizerAdvance
    \/ TraceHandleConfirmMarkActive
    \/ TraceHandleCancelLoopDone
    \/ TraceFinalizerEndOp
    \/ TraceMonitorBegin
    \/ TraceMonitorAdmitBudgets
    \/ TraceEnforceReceiverBudgetsSnapshot
    \/ TraceRefEnforceBudgetSelect
    \/ TraceRefEnforceBudgetRecheck
    \/ TraceMonitorBudgetEndOp
    \/ TraceMonitorNoRetirement
    \/ TraceFinishTransactionIfComplete
    \/ TraceFinishTransactionNotComplete
    \/ TraceMonitorRetireFinished
    \/ TraceMonitorRetireTimeout
    \/ TraceDeleteTransaction
    \/ TraceShutdown
    \/ TraceRefMakeProgressEvent
    \/ TraceTransactionEmitProgressEvent
    \/ TraceTransactionProgressCallbackReturn
    \/ TraceCheckedExecutorEnqueue
    \/ TraceCheckedExecutorSubmitReturn
    \/ TraceCheckedExecutorSubmitRuntimeError
    \/ TraceCheckedExecutorSubmitStopped
    \/ TraceSubmitFinishedSettlementFallback
    \/ TraceSettleFinishedTransactionWorker
    \/ TraceTransactionDoneDrainBegin
    \/ TraceTransactionDoneDrainEmpty
    \/ TraceTransactionDoneDrainExpired
    \/ TraceTransactionDoneSnapshotRef
    \/ TraceTransactionDoneComputeOutcome
    \/ TraceTransactionDoneComputeException
    \/ TraceTransactionDoneTerminalProgress
    \/ TraceTransactionDoneProgressReturned
    \/ TraceTransactionDoneSnapshotBaseObject
    \/ TraceTransactionDoneObjectsBegin
    \/ TraceTransactionDoneObjectCallback
    \/ TraceTransactionDoneObjectReturned
    \/ TraceTransactionDoneTransactionCallback
    \/ TraceTransactionDoneOutcomeCallback
    \/ TraceTransactionDoneReleaseBegin
    \/ TraceTransactionDoneRelease
    \/ TraceTransactionDoneReleaseReturned
    \/ TraceInvokeCallbackSafely
    \/ TraceReleaseSourceReference
    \/ TraceCallbackReturn
    \/ TraceCallbackException
    \/ TraceTransactionDoneRecordReady
    \/ TraceRecordOutcome
    \/ TraceRecordOutcomeDrop
    \/ TraceTransactionDoneComplete
    \/ TraceSyncTerminationMarkerRead
    \/ TraceSyncTerminationMarkerWrite
    \/ TraceReapTerminationMarker
    \/ TraceExpireOutcome
    \/ TraceGetTransferWaiter
    \/ TraceWaitForResultTransfers
    \/ TraceAdvanceTime
    \/ TraceHandleDownloadProduceError
    \/ TraceConsumerReceiveProducerError
    \/ TraceDownloadRequestWorkerStart

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
