# Instrumentation specification: nvflare-transfer

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
| `DownloadObjectStart` | `download_service.py:2164-2182,2203-2209` | send the initial ordinary pull | `p` | `consumer`, `futureStarted`, `pullPC` |
| `HandleDownloadBegin` | `download_service.py:1681-1699,822-833` | admit a pull while holding the table and operation locks | `p` | `ops`, `pullPC` |
| `HandleDownloadMissing` | `download_service.py:1681-1697` | after ref retirement, return retained finished status or missing-ref error; includes a late first acquisition | `p` | `pullPC`, `reply`, `replyNonce` |
| `HandleDownloadMarkActive` | `download_service.py:1701,300-301,774-775` | update the sliding global inactivity clock | `p` | `pullPC`, `txLast` |
| `RefMarkReceiverActive` | `download_service.py:441-444,1702` | capture request time and publish ref activity under progress lock | `p` | `pullPC`, `pullTime`, `refLast` |
| `TransactionMarkReceiverActive` | `download_service.py:445-450` | publish the same captured time under transaction stats lock | `p` | `acquired`, `pullPC`, `receiverLast` |
| `HandleDownloadActiveProgress` | `download_service.py:1703,517-542` | request ACTIVE progress before produce | `p` | `pub`, `pullPC` |
| `HandleDownloadProduce` | `download_service.py:1707-1716,1724,1751-1775` | ordinary produce returns DATA then EOF; transport contents abstracted | `p` | `pullPC`, `rc` |
| `HandleDownloadProduceException` | `download_service.py:1715-1722` | ordinary produce exception prepares FAILED progress and PROCESS_EXCEPTION | `p` | `pub`, `pullPC`, `rc` |
| `RefObjServed` | `download_service.py:369-397,1728-1732` | record a provisional serve or return no nonce when already final | `p` | `nonce`, `pending`, `provisional`, `pullPC` |
| `HandleDownloadTerminalProgress` | `download_service.py:1733-1749` | choose progress from returned serve nonce and producer RC, outside progress lock | `p` | `pub`, `pullPC` |
| `HandleDownloadDataProgress` | `download_service.py:1752-1775` | count one abstract data unit and prepare ACTIVE progress | `p` | `nonce`, `pub`, `pullPC` |
| `HandleDownloadEndOp` | `download_service.py:1750,1768-1779,835-839` | finally leaves the operation gate before the reply becomes receivable | `p` | `ops`, `pullPC`, `reply`, `replyNonce` |
| `ConsumerReceiveData` | `download_service.py:2212-2213,2291-2298` | receive DATA and remember cancel capability; one unit consumed next | `p` | `consumer`, `index`, `reply` |
| `ConsumerLaunchPipeline` | `download_service.py:2300-2305` | submit next request BEFORE calling consume on the current data | `p` | `consumer`, `futureStarted`, `pullPC` |
| `ConsumerConsumeReturn` | `download_service.py:2309-2310,2333-2349` | value-stable consume returns; wait for the already submitted request | `p` | `consumer` |
| `ConsumerConsumeException` | `download_service.py:2311-2317` | consume raises; cancel an unstarted future, but an admitted request keeps running | `p` | `abandoned`, `cancelWire`, `consumer`, `consumerResult`, `pullPC` |
| `ConsumerReceiveEOF` | `download_service.py:2260-2274` | receive EOF and enter download_completed before sending any confirmation | `p` | `consumer`, `consumerNonce`, `reply` |
| `ConsumerDownloadCompleted` | `download_service.py:2273-2283` | download_completed returns successfully | `p` | `consumer`, `consumerResult` |
| `ConsumerDownloadCompletedException` | `download_service.py:2273-2281` | download_completed raises and schedules FAILED confirmation | `p` | `consumer`, `consumerResult` |
| `ConsumerSendConfirm` | `download_service.py:2083-2105,2279-2283` | send receiver truth only if terminal reply requested nonce-bound confirmation | `p` | `confirmWire`, `consumer` |
| `ConsumerReceiveError` | `download_service.py:2221-2250` | ordinary failed request causes cancellation after acquisition | `p` | `abandoned`, `cancelWire`, `consumer`, `consumerResult`, `reply` |
| `LoseConfirmation` | `download_service.py:2083-2105,456-469` | best-effort confirmation fails to arrive; receiver budgets remain the backstop | `p` | `confirmWire` |
| `HandleConfirmBegin` | `download_service.py:1782-1799,822-833` | admit confirmation, preserving nonce requirement for the later final-status lock | `p` | `confirmWire`, `fpc`, `ftodo`, `ops` |
| `HandleConfirmLate` | `download_service.py:1783-1793` | drop confirmation after retirement/closed gate | `p` | `confirmWire` |
| `HandleCancelBegin` | `download_service.py:1814-1827,822-833` | admit cancellation before testing transaction-level acquisition | `c` | `cancelWire`, `fpc`, `ops` |
| `HandleCancelLate` | `download_service.py:1816-1822` | drop cancellation after retirement/closed gate | `c` | `cancelWire` |
| `HandleCancelAcquired` | `download_service.py:1828-1839` | snapshot acquired membership, then iterate all fixed sibling refs | `c` | `fpc`, `ftodo` |
| `FinalizerSelectRef` | `download_service.py:1799,1838-1839,306-308` | select the next ref before acquiring its progress lock | `t`, `p` | `fp`, `fpc`, `ftodo` |
| `RefFinalizeReceiverCommit` | `download_service.py:313-335` | atomic dedup, pending guard, pop, status record and downloaded_to_all latch | `t` | `allDone`, `cb`, `faccepted`, `fall`, `fpc`, `fwon`, `pending`, `provisional`, `status` |
| `RefDownloadedToOneReturned` | `download_service.py:342-357` | after guarded downloaded_to_one, independently invoke downloaded_to_all if latched | `t` | `cb`, `fpc` |
| `RefDownloadedToAllReturned` | `download_service.py:350-357` | guarded downloaded_to_all returns to the caller | `t` | `cb`, `fpc` |
| `RefFinalizerProgress` | `download_service.py:411-429,510-514` | after callback return select receiver truth for progress (separate from final commit) | `t` | `fpc`, `pub` |
| `FinalizerAdvance` | `download_service.py:423-430,504-515,1799-1801,1838-1839` | after receiver publication return to the sibling/candidate loop | `t` | `fpc` |
| `HandleConfirmMarkActive` | `download_service.py:1799-1803` | accepted confirmation refreshes transaction clock only, after its callbacks | `p` | `fpc`, `txLast` |
| `HandleCancelLoopDone` | `download_service.py:1838-1841` | all sibling cancellation attempts returned | `c` | `fpc` |
| `FinalizerEndOp` | `download_service.py:1802-1810,1840-1844,835-839` | end operation BEFORE requesting finish-if-complete | `t` | `finishReady`, `fpc`, `ops` |
| `MonitorBegin` | `download_service.py:1848-1863` | capture monitor time before budget operations; no absolute transaction-age deadline | empty object | `monitorNow`, `monitorPC` |
| `MonitorAdmitBudgets` | `download_service.py:1856-1865,822-833` | register budget pass as an operation if the transaction is still live | empty object | `fpc`, `monitorPC`, `ops` |
| `EnforceReceiverBudgetsSnapshot` | `download_service.py:857-873` | capture receiver activity once per transaction budget pass under stats lock | empty object | `budgetLast`, `budgetNow`, `faccepted`, `fpc`, `ftodo` |
| `RefEnforceBudgetSelect` | `download_service.py:475-502` | select a candidate from declared identities; test acquisition/idle using captured receiver clock | `p` | `fp`, `fpc`, `ftodo` |
| `RefEnforceBudgetRecheck` | `download_service.py:504-510` | freshness recheck under stats lock; release it BEFORE final-status commit | empty object | `fpc` |
| `MonitorBudgetEndOp` | `download_service.py:1864-1871,835-839` | finish all budget callbacks and leave gate before classification | empty object | `fpc`, `monitorPC`, `ops` |
| `MonitorNoRetirement` | `download_service.py:1875-1890,1909` | classification leaves a live nonexpired transaction, or notices another terminator won | empty object | `monitorPC` |
| `FinishTransactionIfComplete` | `download_service.py:1411-1425,1525-1541` | table-locked single-winner retirement; monotone final-status scan linearizes at successful check | `t` | `cause`, `finishReady`, `live`, `submitPC`, `terminating`, `tombstoneAt` |
| `FinishTransactionNotComplete` | `download_service.py:1420-1422` | helper observes missing transaction or a ref that is not complete | `t` | `finishReady` |
| `MonitorRetireFinished` | `download_service.py:1875-1890,1903-1907` | monitor retires a finished transaction and schedules its own inline settlement | empty object | `cause`, `live`, `monitorPC`, `spc`, `terminating`, `tombstoneAt` |
| `MonitorRetireTimeout` | `download_service.py:1880-1887,1897-1901` | only after not-finished test, retire on sliding inactivity using monitor sampled time | empty object | `cause`, `live`, `monitorPC`, `spc`, `terminating` |
| `DeleteTransaction` | `download_service.py:1399-1408,1525-1541` | explicit deletion atomically wins table ownership, then runs settlement outside the lock | empty object | `cause`, `live`, `spc`, `terminating` |
| `Shutdown` | `download_service.py:1457-1497` | atomically clear ownership and receipts; resolve pending waiters with None BEFORE cleanup | empty object | `cause`, `lateWaiter`, `live`, `owner`, `retained`, `shutdown`, `spc`, `terminating`, `waiter` |
| `RefMakeProgressEvent` | `download_service.py:526-612` | construct or suppress a progress event atomically, latching first terminal state | `t` | `progressBytes`, `progressOrder`, `progressSeq`, `progressStarted`, `progressTerminal`, `pub` |
| `TransactionEmitProgressEvent` | `download_service.py:539-542,1004-1013` | invoke public source progress callback after releasing progress lock | `t`, `e` | `observedTerminal`, `pub` |
| `TransactionProgressCallbackReturn` | `download_service.py:1008-1013` | progress callback returns or its ordinary Exception is contained; no unmodeled callback mutation | `t` | `pub` |
| `CheckedExecutorEnqueue` | `stream_utils.py:60-78; concurrent/futures/thread.py:199-216` | enqueue settlement before submission acknowledgement (brief S3; saved stdlib evidence) | empty object | `queued`, `submitPC` |
| `CheckedExecutorSubmitReturn` | `stream_utils.py:65-66; concurrent/futures/thread.py:199-216` | return the Future; the worker may already have started | empty object | `submitPC` |
| `CheckedExecutorSubmitRuntimeError` | `stream_utils.py:71-78; download_service.py:1435-1441` | post-enqueue non-shutdown RuntimeError propagates; DownloadService selects fallback without dequeuing | empty object | `submitPC` |
| `CheckedExecutorSubmitStopped` | `stream_utils.py:61-64,79-81; download_service.py:1442-1446` | executor declines submission before enqueue and returns None | empty object | `submitPC` |
| `SubmitFinishedSettlementFallback` | `download_service.py:1442-1454` | run inline fallback; no settlement-entry dedup latch exists | empty object | `spc`, `submitPC` |
| `SettleFinishedTransactionWorker` | `stream_utils.py:65-78,84-85; download_service.py:1449-1454` | a runnable worker dequeues the existing settlement item, even if submission reported error | empty object | `queued`, `spc` |
| `TransactionDoneDrainBegin` | `download_service.py:895-906,841-850` | each settlement invocation independently closes gate and establishes its own drain deadline | `t` | `closed`, `drainAt`, `spc` |
| `TransactionDoneDrainEmpty` | `download_service.py:841-851,910` | drain returns normally once all admitted operations ended | `t` | `spc`, `todo` |
| `TransactionDoneDrainExpired` | `download_service.py:846-849,905-910` | after the bounded wait, proceed even with outstanding operations | `t` | `drainForced`, `spc`, `todo` |
| `TransactionDoneSnapshotRef` | `download_service.py:910,918-927,432-434` | copy one complete per-ref status map under that ref lock; refs are snapshotted separately | `t`, `r` | `snapshots`, `todo` |
| `TransactionDoneComputeOutcome` | `download_service.py:918-928; transfer_outcome.py:156-202,242-271` | compute strict success and common-receiver quorum from the frozen matrix | `t` | `spc`, `todo`, `verdicts` |
| `TransactionDoneComputeException` | `download_service.py:929-933,803-820` | contained computation Exception creates an empty fail-closed verdict and still executes cleanup | `t` | `spc`, `todo`, `verdicts` |
| `TransactionDoneTerminalProgress` | `download_service.py:935-938,544-564,576-612` | under one ref lock, set ref-wide terminal override and construct all started-receiver events | `t`, `r` | `progressSeq`, `progressTerminal`, `pub`, `refTerminal`, `todo` |
| `TransactionDoneProgressReturned` | `download_service.py:935-953` | finish terminal progress callbacks before capturing the base objects | `t` | `spc`, `todo` |
| `TransactionDoneSnapshotBaseObject` | `download_service.py:948-953` | snapshot each infrastructure source reference before object callbacks; another settlement may already release it | `t`, `r` | `baseObjects`, `todo` |
| `TransactionDoneObjectsBegin` | `download_service.py:953-955` | begin per-object transaction_done callback loop | `t` | `spc`, `todo` |
| `TransactionDoneObjectCallback` | `download_service.py:955-964` | prepare one guarded object transaction_done callback | `t`, `r` | `cb`, `todo` |
| `TransactionDoneObjectReturned` | `download_service.py:955-964` | return to loop after this object hook returned or raised | `t` | `cb` |
| `TransactionDoneTransactionCallback` | `download_service.py:966-975` | invoke configured transaction_done_cb with this invocation's base-object snapshot | `t` | `cb`, `spc` |
| `TransactionDoneOutcomeCallback` | `download_service.py:977-978` | after transaction callback return, invoke outcome_cb BEFORE source releases | `t` | `cb`, `spc` |
| `TransactionDoneReleaseBegin` | `download_service.py:977-989` | finally begins release loop despite guarded callback Exceptions | `t` | `cb`, `spc`, `todo` |
| `TransactionDoneRelease` | `download_service.py:985-989` | prepare each independently guarded release attempt | `t`, `r` | `cb`, `todo` |
| `TransactionDoneReleaseReturned` | `download_service.py:988-989` | continue release loop after this source release returned or raised | `t` | `cb` |
| `InvokeCallbackSafely` | `download_service.py:645-655,342-356,958-989` | enter user hook; observer counts invocations/attempts, independently of return or exception | `t`, `arg` | `cb`, `doneCalls`, `effectsAfterReceipt`, `objectDoneCalls`, `outcomeCbCalls`, `releaseAttempts` |
| `ReleaseSourceReference` | `cacheable.py:109-120; download_service.py:193-201,988-989` | owned-source release drops only the infrastructure reference, before its hook returns | `t` | `cb`, `sourceHeld` |
| `CallbackReturn` | `download_service.py:645-655` | finite callback returns; no caller phase advances until this return | `t` | `cb` |
| `CallbackException` | `download_service.py:645-655,985-989` | ordinary callback/release Exception is contained; already visible effects are not undone | `t` | `callbackErrors`, `cb` |
| `TransactionDoneRecordReady` | `download_service.py:988-999` | all this invocation's release attempts have returned before on_outcome recording | `t` | `spc` |
| `RecordOutcome` | `download_service.py:1579-1595,998-1000` | owner-guarded single receipt write; resolve pending waiters atomically with recording | `t` | `lateOutcome`, `lateWaiter`, `owner`, `receipt`, `receiptWrites`, `recordAt`, `recordedBy`, `retained`, `spc`, `waiter`, `waiterOutcome` |
| `RecordOutcomeDrop` | `download_service.py:1582-1585,998-1000` | ownership consumed by another record or cleared by shutdown: discard duplicate receipt | `t` | `spc` |
| `TransactionDoneComplete` | `download_service.py:1000-1002` | set settlement_complete after recording returns; this is not an entry latch | `t` | `settlementComplete`, `spc` |
| `SyncTerminationMarkerRead` | `download_service.py:1500-1505` | snapshot whether admitted operations remain under operation lock | `t` | `markerLeaked`, `spc` |
| `SyncTerminationMarkerWrite` | `download_service.py:1506-1510` | sustain or clear marker under table lock using sampled operation state | `t` | `spc`, `terminating` |
| `ReapTerminationMarker` | `download_service.py:1513-1522` | monitor removes a quiescent marker; remaining settlement duplication is not counted by this latch | empty object | `terminating` |
| `ExpireOutcome` | `download_service.py:1611-1619; transfer_outcome.py:181-182` | remove retained receipt after strict greater-than TTL; previously resolved waiters retain their value | empty object | `retained` |
| `GetTransferWaiter` | `download_service.py:1544-1565` | attach a second observer; unswept expired receipt still resolves it, exactly as current API | empty object | `lateOutcome`, `lateWaiter` |
| `WaitForResultTransfers` | `nvflare/client/cell/api.py:624-648` | minimal caller barrier: only a non-None strict COMPLETED receipt permits success | empty object | `caller` |
| `AdvanceTime` | `download_service.py:441-442,774-775,843-849,1850,1909` | advance abstract monotone wall time; monitor execution remains independent | empty object | `now` |
| `HandleDownloadProduceError` | `download_service.py:1716,1724-1732` | produce returns ERROR as an ordinary functional outcome, provisionally awaiting receiver truth | `p` | `pullPC`, `rc` |
| `ConsumerReceiveProducerError` | `download_service.py:2260-2265,2285-2289` | terminal ERROR carries nonce; prepare FAILED confirmation without download_completed | `p` | `consumer`, `consumerNonce`, `consumerResult`, `reply` |
| `DownloadRequestWorkerStart` | `download_service.py:2166-2182,2300-2305,2312-2313` | the submitted pipeline future starts before remote admission; cancel can no longer erase the request | `p` | `futureStarted` |

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
