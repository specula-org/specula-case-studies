# Bug Report — nvflare-transfer

## Summary

- Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.
- Convergence: one round; 16/16 implementation traces pass, then the unchanged `MC.cfg` runs its full 30-minute budget without a violation. This is budgeted convergence, not an exhaustive proof: last reported 188,559,267 distinct states, depth 21, and 103,310,511 queued states.
- Hunting: all four original configurations executed, covering S1, S3 and S4 with S2/S5 merged as described in `brief-coverage.md`.
- Bugs found: 2 Case C implementation findings, supported by three TLC counterexamples. No Case A invariant revision or Case B model repair was needed.
- Status: complete. All four BFS hunts and the required S4 simulation have ended and their outputs are recorded. The standard and S4 BFS searches were not exhaustive.

All unqualified affected-code paths below are under `nvflare/fuel/f3/streaming/` at the source pin. Uninstrumented source copies are in `output/pinned-source/`. Every counterexample has the original TLC output, JSON dump, installed `get_tlc_summary` result, complete states, last-state inspection and last-state comparison under `output/`. TLC labels many normal transitions `MCNext`; the semantic names below are determined from their changed fields and the corresponding base action definitions, not fabricated runtime events.

## Bug 1: Post-enqueue submission failure duplicates settlement effects and permits callbacks after receipt

- **ID**: MC-1
- **Scenario**: S3, with S5 callback/source/waiter ordering
- **Severity**: Medium
- **Classification**: Case C — implementation contract violation
- **Invariant violated**: `SingleSettlementEffects`; independently `NoSettlementEffectsAfterReceipt`
- **Config**: `MC_hunt_s3_settlement.cfg`; `MC_hunt_s3_after_receipt.cfg`
- **Counterexamples**: 77 states in [MC_hunt_s3_settlement_bfs.out](output/MC_hunt_s3_settlement_bfs.out); 94 states in [MC_hunt_s3_after_receipt_bfs.out](output/MC_hunt_s3_after_receipt_bfs.out).

### Trace Summary

The 77-state counterexample:

1. States 1–52: one explicitly declared receiver downloads the registered ref, completes consumption and sends matching confirmation; SUCCESS is finalized, callbacks/progress return, and the confirmation leaves the operation gate.
2. State 53: `FinishTransactionIfComplete` wins retirement under the table lock.
3. State 54: `CheckedExecutorEnqueue` publishes the settlement work item. State 55: an available worker dequeues it. States 56–61 advance that worker through the empty drain, frozen successful verdict and terminal-progress phase.
4. State 62: `MCCheckedExecutorSubmitRuntimeError` reports the post-enqueue submission failure. The work already belongs to the worker; the exception does not retract it.
5. State 63: `SubmitFinishedSettlementFallback` enters a second, inline settlement. Both invocations independently snapshot the source and prepare its object-done callback.
6. States 76–77: inline and worker each enter that callback; `objectDoneCalls[ref1]` becomes 2. `receiptWrites` is still 0, so this demonstrates duplicate effects independently of receipt publication.

The separate 94-state counterexample preserves the same enqueue/error/fallback mechanism (states 55–60), then delays the worker's object callback at its ready checkpoint. Inline settlement executes its object, transaction and outcome callbacks (states 76–86), attempts release (state 89), contains an ordinary release exception (state 90), and records a successful receipt/resolves the waiter (state 93). At state 94 the worker enters the object's callback: `effectsAfterReceipt = TRUE` and `objectDoneCalls[ref1] = 2`, while `receiptWrites = 1`. This particular counterexample includes a failed release attempt; it does not claim physical reclamation preceded the late callback.

### Root Cause

`CheckedExecutor.submit` calls the standard executor and rethrows a non-shutdown RuntimeError (`stream_utils.py:60-78`). The actual Python 3.14.4 executor publishes `_work_queue.put(w)` before `_adjust_thread_count()` and its possible thread-start exception (`concurrent/futures/thread.py:199-237`). A worker can already own the item, or a later worker can acquire it.

`DownloadService._submit_finished_settlement` catches every RuntimeError and calls `_settle_finished_transaction` inline (`download_service.py:1429-1454`). Atomic table retirement protects the choice of terminator, but neither `_settle_finished_transaction` nor `_Transaction.transaction_done` has an entry latch. Both calls therefore execute callbacks and release attempts. `_record_outcome` checks ownership only after those effects (`download_service.py:1579-1595`): it prevents a second stored receipt, not a second settlement chain. `_settlement_complete` is written at the end, not acquired at entry.

This violates the explicit `transaction_done` contract that it runs once and that a returned waiter cannot precede its callback/release ceremony (`download_service.py:895-903`). Those promises are not merely FINISHED-versus-COMPLETED semantics. The trace retains real receiver-confirmed SUCCESS and the original single-receipt guard; no incorrect receiver count, late registration or arbitrary duplicate task is assumed.

### Fidelity and Evidence Boundary

| Required condition | Source guard audit |
|---|---|
| Work survives submission failure | Standard executor enqueues first; `CheckedExecutor` rethrows the non-shutdown error without dequeue/cancellation. |
| Worker may run before the error is reported | Workers consume the queue independently of the submitter's acknowledgement; an existing runnable worker is sufficient. No model assumption forces the failing new thread itself to execute. |
| Fallback and worker both enter settlement | DownloadService's broad catch selects fallback; the settled/terminating flags provide no entry exclusion. |
| Late callbacks remain possible despite one receipt | Receipt-owner dedup occurs after callbacks and release attempts; it cannot undo or exclude their earlier entry. |

The existing, provenance-checked Phase 2.5 `queue_then_submit_exception` implementation trace supplies controlled local evidence for the same mechanism. Actual enqueue is event 203, injected submit error 204, fallback 205, receipt recording 243, later worker entry 247 and duplicate record rejection 285. Its final observations are two object/transaction/outcome callbacks and two release attempts per source, one receipt, and `effectsAfterReceipt = TRUE`; unlike the 94-state model counterexample, this trace has no lifecycle callback exception. Both registered `base_obj` references were dropped by its successful releases; application/observer aliases and physical GC are outside that observation.

That fixture injects `_adjust_thread_count` failure in a dedicated real CheckedExecutor. It establishes implementation behavior after that failure, not spontaneous production triggering or the exact earlier-worker schedules in the TLC counterexamples. No resource-exhaustion campaign or independent Phase 4 reproduction was run. Impact depends on configured hook side effects; data corruption or a false receiver-success certificate has not been established.

### Affected Code

- `nvflare/fuel/f3/streaming/stream_utils.py:60`: submission wrapper and non-shutdown RuntimeError propagation.
- `nvflare/fuel/f3/streaming/download_service.py:1429`: fallback selection after submission error.
- `nvflare/fuel/f3/streaming/download_service.py:1449`: worker/fallback share the same unguarded settlement entry.
- `nvflare/fuel/f3/streaming/download_service.py:895`: settlement effects and once-only contract.
- `nvflare/fuel/f3/streaming/download_service.py:1579`: receipt-only ownership guard occurs after effects.

### Recommendation

Make settlement-entry ownership atomic for each transaction before any drain, snapshot, callback or release effect. Both worker and fallback must consult the same entry guard; only its winner should execute the ceremony. Preserve the final receipt owner check and existing callback exception handling. Treat this as one root cause with two observable contract violations.

## Bug 2: A pipelined EOF can publish COMPLETED progress after cancellation finalized FAILED

- **ID**: MC-2
- **Scenario**: S1 receiver truth versus source terminal progress
- **Severity**: Medium
- **Classification**: Case C — implementation contract violation
- **Invariant violated**: `CompletedProgressHasReceiverSuccess`
- **Config**: `MC_hunt_s1_progress.cfg`
- **Counterexample**: 35 states in [MC_hunt_s1_progress_bfs.out](output/MC_hunt_s1_progress_bfs.out).

### Trace Summary

1. States 1–17: the confirmed-mode receiver acquires the ref and receives one ordinary DATA chunk, establishing supported cancellation capability.
2. States 18–20: the Consumer launches the next pipeline request before consuming the current chunk; that future starts and the producer admits the operation.
3. States 21–26: the admitted request reaches ordinary EOF. It has not yet called `obj_served`.
4. State 27: `MCConsumerConsumeException` records the Consumer failure and sends cancellation. The already started/admitted request remains alive.
5. States 28–31: cancellation passes the acquired-receiver check, commits final FAILED under the ref lock, and pauses before its downloaded-to-one callback/progress publication. The ref's final-status lock is released.
6. State 32: `RefObjServed` observes an already-final receiver and returns no nonce. State 33: the terminal serve chooses COMPLETED from EOF because the `expect_confirm and serve_nonce` condition is false.
7. State 34: the first terminal-progress event is latched as COMPLETED. State 35: its public callback is delivered with sequence 3 and one byte, while the winning receiver status remains FAILED and the Consumer result remains FAILED.

### Root Cause

The supported pipeline starts the next request before `consume` and cannot cancel an already-running future (`download_service.py:2300-2317`). Cancellation commits FAILED under `_progress_lock` but invokes object callbacks and publishes its FAILED progress after releasing that lock (`download_service.py:313-357,425-429`). The admitted EOF may therefore enter `obj_served` in that gap.

`obj_served` correctly returns None for an already-final receiver (`download_service.py:392-395`). Its caller, however, uses the absence of the returned nonce to enter the same branch as a legacy/confirmation-disabled serve and selects COMPLETED solely from EOF (`download_service.py:1728-1749`). The receiver can still be confirm-capable with final FAILED. `_make_progress_event_locked` latches the first terminal state and suppresses all subsequent terminal events (`download_service.py:587-612`), so the cancellation's later FAILED progress cannot correct the public terminal notification.

### Fidelity and Evidence Boundary

| Required condition | Source guard audit |
|---|---|
| Cancellation after acquisition while an EOF request remains active | DATA advertises cancellation; the pipeline future starts before consume; `Future.cancel()` does not retract an admitted producer operation. |
| EOF after FAILED status but before FAILED progress | The status critical section ends before callbacks and progress; the operation gate admits both while the transaction is still live. |
| No nonce with confirmation enabled | `obj_served` explicitly returns None on an already-final status even when `expect_confirm=True`. |
| Wrong terminal state persists | First-terminal suppression blocks the later cancellation notification. |

This is not a demand for stronger semantics from legacy peers: both confirmation switches are enabled in the hunt. No retry, nonce reuse, unacquired cancellation, disabled-confirmation path, late registration or abnormal payload is required. The desired property follows the receiver-truth progress selection in `obj_confirmed`/`obj_cancelled` and the confirmed-mode terminal-serving comments, while the invariant remains enabled and falsifiable.

The actual 16-trace corpus conforms to the model and includes admitted pipeline work surviving consume failure, but it does **not** contain this contradictory COMPLETED delivery schedule. Classification here is supported by the TLC counterexample and source mapping; an independent deterministic runtime regression for this exact schedule remains pending. The counterexample stops before receipt settlement. It does not establish a false successful strict receipt: the receiver map is FAILED. The inspected Client API progress hook is a no-op and its barrier checks strict TransferOutcome COMPLETED (`nvflare/client/cell/api.py:481-487,624-648`), so false trainer-send success is not claimed.

### Affected Code

- `nvflare/fuel/f3/streaming/download_service.py:313`: final-status commit and subsequent unlocked callbacks.
- `nvflare/fuel/f3/streaming/download_service.py:392`: already-final receiver returns no serve nonce.
- `nvflare/fuel/f3/streaming/download_service.py:425`: cancellation publishes FAILED after finalization callbacks.
- `nvflare/fuel/f3/streaming/download_service.py:587`: first-terminal progress suppression.
- `nvflare/fuel/f3/streaming/download_service.py:1728`: EOF/nonce branch can select contradictory COMPLETED.
- `nvflare/fuel/f3/streaming/download_service.py:2300`: supported pipeline admission before consume failure.

### Recommendation

Keep confirmed-mode already-final handling distinct from legacy producer-served completion. Derive terminal progress from the winning receiver status, or suppress this late terminal serve's progress when finalization already owns the terminal notification. Preserve the atomic status/pending update and legacy wire behavior.

## Not Reproduced

| Scenario or property | Config / evidence | States explored | Result |
|---|---|---:|---|
| Standard safety and structural invariants | `MC.cfg` | Last reported 188,559,267 distinct, depth 21; 103,310,511 queued | No violation within 30 minutes; not exhaustive. |
| S4 receiver budgets with S2 aggregation/S5 cleanup | `MC_hunt_s4_budgets.cfg` | Last reported 163,706,943 distinct, depth 21; 86,654,088 queued | BFS and required depth-100 simulation: no violation within each 30-minute budget. Simulation last reported 4,664,773 model traces; not exhaustive. |
| Main confirmed-mode runtime conformance | 16 original Trace replays | 3,029 observed events, 94 action names | All pass; finite observed behaviors, not exhaustive interleaving coverage. |
| Conditional eventual waiter settlement | `FairSpec` / `EventualSettlementObservation` | Not run | Not enabled in supplied finite safety configs; no liveness proof. |
| Caller fanout metadata, count-only/legacy modes | Existing Phase 2.5 profile evidence | 11 tests, reused with checked provenance | Separate contract evidence, not new MC findings or full externalized-payload reproductions. |

## Search Coverage

All original bounds were preserved. Each BFS was configured with a 30-minute limit and stopped early only upon finding a violation. Each of the three other hunts found a violation, so the conditional simulation follow-up did not apply. Budget-stopped rows use the last reported progress sample; TLC emitted no final state counts for those runs.

| Config | Generated | Distinct | Queued (last reported) | TLC reported depth | Counterexample states | Result |
|---|---:|---:|---:|---:|---:|---|
| `MC_hunt_s1_progress.cfg` | 4,321 | 1,515 | 174 | 37 | 35 | MC-2 |
| `MC_hunt_s3_settlement.cfg` | 6,807 | 2,418 | 148 | 80 | 77 | MC-1, duplicate effects |
| `MC_hunt_s3_after_receipt.cfg` | 44,459 | 13,906 | 868 | 94 | 94 | MC-1, effects after receipt |
| `MC_hunt_s4_budgets.cfg` (BFS) | 646,515,586 | 163,706,943 | 86,654,088 | 21 | — | No violation within 30 minutes; not exhaustive |

Reported BFS depth can exceed the saved counterexample length because other workers advanced before termination. Nonempty queues in violating runs do not invalidate the concrete counterexample. No specification or invariant was weakened during hunting. Full priority-question coverage and remaining abstraction limits are in [validation-report.md](validation-report.md).

The required S4 simulation ran for its full 30-minute budget using the same cfg, depth limit 100, trace limit 999999999 and seed 5801817375106481733. It found no violation; last reported statistics were **624,958,988 states checked and 4,664,773 random model traces generated**. These counters are not distinct-state counts or implementation-trace counts, and not every trajectory reaches the configured depth limit. See [MC_hunt_s4_budgets_sim.out](output/MC_hunt_s4_budgets_sim.out) and its request/result/summary companions.
