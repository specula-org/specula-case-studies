-------------------------------- MODULE MC --------------------------------
EXTENDS base
Original == INSTANCE base
CONSTANTS TimeLimit, ConsumerLimit, ProduceLimit, LossLimit, DeleteLimit,
          ShutdownLimit, SubmitLimit, ExecutorStopLimit, CallbackLimit,
          ComputeLimit, MessageLimit
VARIABLE faultCounts
mcvars == <<st, faultCounts>>
\* download_service.py:1715-1722: bound the injected produce choice only.
MCHandleDownloadProduceException(p) ==
    /\ faultCounts.produce < ProduceLimit
    /\ Original!HandleDownloadProduceException(p)
    /\ faultCounts' = [faultCounts EXCEPT !.produce = @ + 1]

\* download_service.py:2311-2317: bound the injected consumer choice only.
MCConsumerConsumeException(p) ==
    /\ faultCounts.consumer < ConsumerLimit
    /\ Original!ConsumerConsumeException(p)
    /\ faultCounts' = [faultCounts EXCEPT !.consumer = @ + 1]

\* download_service.py:2273-2281: bound the injected consumer choice only.
MCConsumerDownloadCompletedException(p) ==
    /\ faultCounts.consumer < ConsumerLimit
    /\ Original!ConsumerDownloadCompletedException(p)
    /\ faultCounts' = [faultCounts EXCEPT !.consumer = @ + 1]

\* download_service.py:2083-2105,456-469: bound the injected loss choice only.
MCLoseConfirmation(p) ==
    /\ faultCounts.loss < LossLimit
    /\ Original!LoseConfirmation(p)
    /\ faultCounts' = [faultCounts EXCEPT !.loss = @ + 1]

\* download_service.py:1399-1408,1525-1541: bound the injected delete choice only.
MCDeleteTransaction ==
    /\ faultCounts.delete < DeleteLimit
    /\ Original!DeleteTransaction
    /\ faultCounts' = [faultCounts EXCEPT !.delete = @ + 1]

\* download_service.py:1457-1497: bound the injected shutdown choice only.
MCShutdown ==
    /\ faultCounts.shutdown < ShutdownLimit
    /\ Original!Shutdown
    /\ faultCounts' = [faultCounts EXCEPT !.shutdown = @ + 1]

\* stream_utils.py:71-78; download_service.py:1435-1441: bound the injected submit choice only.
MCCheckedExecutorSubmitRuntimeError ==
    /\ faultCounts.submit < SubmitLimit
    /\ Original!CheckedExecutorSubmitRuntimeError
    /\ faultCounts' = [faultCounts EXCEPT !.submit = @ + 1]

\* stream_utils.py:61-64,79-81; download_service.py:1442-1446: bound the injected executorStop choice only.
MCCheckedExecutorSubmitStopped ==
    /\ faultCounts.executorStop < ExecutorStopLimit
    /\ Original!CheckedExecutorSubmitStopped
    /\ faultCounts' = [faultCounts EXCEPT !.executorStop = @ + 1]

\* download_service.py:929-933,803-820: bound the injected compute choice only.
MCTransactionDoneComputeException(t) ==
    /\ faultCounts.compute < ComputeLimit
    /\ Original!TransactionDoneComputeException(t)
    /\ faultCounts' = [faultCounts EXCEPT !.compute = @ + 1]

\* download_service.py:645-655,985-989: bound the injected callback choice only.
MCCallbackException(t) ==
    /\ faultCounts.callback < CallbackLimit
    /\ Original!CallbackException(t)
    /\ faultCounts' = [faultCounts EXCEPT !.callback = @ + 1]

\* download_service.py:441-442,774-775,843-849,1850,1909: bound the injected time choice only.
MCAdvanceTime ==
    /\ faultCounts.time < TimeLimit
    /\ Original!AdvanceTime
    /\ faultCounts' = [faultCounts EXCEPT !.time = @ + 1]

\* download_service.py:1716,1724-1732: bound the injected produce choice only.
MCHandleDownloadProduceError(p) ==
    /\ faultCounts.produce < ProduceLimit
    /\ Original!HandleDownloadProduceError(p)
    /\ faultCounts' = [faultCounts EXCEPT !.produce = @ + 1]

MCInit == Init /\ faultCounts = [callback |-> 0, compute |-> 0, consumer |-> 0, delete |-> 0, executorStop |-> 0, loss |-> 0, produce |-> 0, shutdown |-> 0, submit |-> 0, time |-> 0]

\* CFG overrides route only FaultNext through wrappers. All normal action
\* instances (including callback return, dequeue, drain expiry, end_op and
\* monitor budget checks) are unrestricted and preserve fault counters.
MCNext == (ReactiveNext /\ UNCHANGED faultCounts) \/ FaultNext
MCSpec == MCInit /\ [][MCNext]_mcvars
Symmetry == Permutations(Receivers)
\* A display projection is useful, but NOT enabled as TLC VIEW: fault budgets
\* change future reachability, so merging states that differ in them is unsafe.
ObservedView == st
MCTypeOK == TypeOK /\ faultCounts \in [callback : 0..CallbackLimit, compute : 0..ComputeLimit, consumer : 0..ConsumerLimit, delete : 0..DeleteLimit, executorStop : 0..ExecutorStopLimit, loss : 0..LossLimit, produce : 0..ProduceLimit, shutdown : 0..ShutdownLimit, submit : 0..SubmitLimit, time : 0..TimeLimit]

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
