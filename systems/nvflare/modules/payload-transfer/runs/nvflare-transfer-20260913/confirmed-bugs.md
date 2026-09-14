# Confirmation Report — nvflare-transfer

## Final Result

Reproduced bugs: 4 = 4 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 4 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | CR-2 | REPRODUCED | yes |
| 4 | CR-4 | REPRODUCED | yes |
| 5 | CR-5 | FALSE POSITIVE | no |

## Entry 1: Post-enqueue submission failure duplicates settlement effects and permits callbacks after receipt

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/fuel/f3/streaming/download_service.py:1492

## Description
`DownloadService._submit_finished_settlement()` catches `RuntimeError` from `callback_thread_pool.submit()` and settles inline, but `CheckedExecutor` can raise a non-shutdown `RuntimeError` after `ThreadPoolExecutor` has already enqueued the settlement work item. When a later worker drains that queued item, `_Transaction.transaction_done()` runs a second time. The outcome-owner guard keeps only one stored receipt, but object callbacks, transaction callbacks, outcome callbacks, and source release attempts already ran twice.

## Trigger scenario
A normal receiver-confirmed transfer reaches EOF, the receiver sends a valid confirmation nonce, and `_finish_transaction_if_complete()` retires the transaction. Then the callback-pool submit follows the MC trace: queued work is published, `RuntimeError("can't start new thread")` is raised, inline fallback settles once, and a recovered worker later runs the queued settlement.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **no**. Normal flow and timing-only delayed callback each settled once.
2. Level 2 injected precondition: admissible MC step. Counterexample state 54 has `queued |-> TRUE` and `submitPC |-> "enqueued"`; state 62 takes `MCCheckedExecutorSubmitRuntimeError`; state 77 has both `inline` and `worker` in `objectDone` with `objectDoneCalls(ref1) = 2`.
3. Real consumer/caller: application-provided `Downloadable.transaction_done` via `download_service.py:993`, `transaction_done_cb` via `download_service.py:1008`, and `outcome_cb` via `download_service.py:1018`. `ObjectDownloader` exposes these callbacks at `obj_downloader.py:65`.
4. Permanence/masking: duplicate callback/release side effects are permanent. `_record_outcome` masks only the duplicate stored receipt/waiter result, not the already-executed side effects.

## Developer intent
The code comment says `transaction_done()` “Runs exactly once per transaction” and that waiter recording occurs after callbacks/release. The fallback comment intends to avoid stranding cleanup during executor shutdown. Git history/issue searches found adjacent PRs (#4906 async settlement, #5097 non-shutdown RuntimeError preservation), but no existing issue/PR reporting this exact duplicate settlement mechanism.

## Reproduction result
Test written and executed:
`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugMC-1_post_enqueue_settlement.py`

Command:
```sh
timeout 2m env PYTHONPATH=/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/MC-1/worktree python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugMC-1_post_enqueue_settlement.py
```

Output:
```text
level0_normal: {'tx_id': 'T9d40bc5e-34eb-4ecb-93b7-2e849a0c977a', 'ref_id': 'Rf4eb3648-18ef-406e-90ca-824092f5ae5c', 'injected_fault': False, 'object_transaction_done_calls': [('T9d40bc5e-34eb-4ecb-93b7-2e849a0c977a', 'finished')], 'transaction_done_cb_calls': [('T9d40bc5e-34eb-4ecb-93b7-2e849a0c977a', 'finished', ('source-object',))], 'outcome_cb_calls': [('T9d40bc5e-34eb-4ecb-93b7-2e849a0c977a', 'completed')], 'release_calls': 1, 'waiter_done': True, 'outcome_completed': True, 'outcome_status': 'completed', 'recorded_outcomes': ['T9d40bc5e-34eb-4ecb-93b7-2e849a0c977a']}
level1_timing_only: {'tx_id': 'Tac77f492-11d0-4821-9bea-044a08bb7ca2', 'ref_id': 'Rae3f204b-4f56-43cc-9fd9-44a4e7f88b46', 'injected_fault': False, 'object_transaction_done_calls': [('Tac77f492-11d0-4821-9bea-044a08bb7ca2', 'finished')], 'transaction_done_cb_calls': [('Tac77f492-11d0-4821-9bea-044a08bb7ca2', 'finished', ('source-object',))], 'outcome_cb_calls': [('Tac77f492-11d0-4821-9bea-044a08bb7ca2', 'completed')], 'release_calls': 1, 'waiter_done': True, 'outcome_completed': True, 'outcome_status': 'completed', 'recorded_outcomes': ['Tac77f492-11d0-4821-9bea-044a08bb7ca2']}
level2_post_enqueue_fault: {'tx_id': 'T50ee0eff-f421-4d2e-9578-a47992464702', 'ref_id': 'R817596fd-d2bf-4479-8197-321f8794b009', 'injected_fault': True, 'object_transaction_done_calls': [('T50ee0eff-f421-4d2e-9578-a47992464702', 'finished'), ('T50ee0eff-f421-4d2e-9578-a47992464702', 'finished')], 'transaction_done_cb_calls': [('T50ee0eff-f421-4d2e-9578-a47992464702', 'finished', ('source-object',)), ('T50ee0eff-f421-4d2e-9578-a47992464702', 'finished', ('source-object',))], 'outcome_cb_calls': [('T50ee0eff-f421-4d2e-9578-a47992464702', 'completed'), ('T50ee0eff-f421-4d2e-9578-a47992464702', 'completed')], 'release_calls': 2, 'waiter_done': True, 'outcome_completed': True, 'outcome_status': 'completed', 'recorded_outcomes': ['T50ee0eff-f421-4d2e-9578-a47992464702']}
BUG_REPRODUCED duplicate settlement side effects with one stored receipt
```

## Recommendation
Add a transaction-level settlement-entry latch before any `transaction_done()` side effects, or otherwise claim settlement ownership before callbacks/release. The owner guard must protect the whole settlement ceremony, not only the final receipt write.

---

## Entry 2: A pipelined EOF can publish COMPLETED progress after cancellation finalized FAILED

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: nvflare/fuel/f3/streaming/download_service.py:1815

## Description
MC-2 is reproduced. In receiver-confirmed mode, a pipelined EOF request can be admitted before `Consumer.consume()` fails. The receiver-side cancel finalizes the receiver as `FAILED`; while cancellation callbacks/progress are still outside the finalization lock, the already-started EOF handler sees no serve nonce and emits source progress `COMPLETED`. The terminal progress latch then prevents the later `FAILED` source progress from replacing it.

Known-status search found no upstream issue or recently merged/closed PR for this exact pipelined EOF/cancel/source-progress contradiction. Related PRs introduced receiver-confirmed completion, pipelining, and cancel cleanup, but did not report or fix this mechanism.

## Trigger scenario
1. Receiver-confirmed transfer with an expected receiver and a pipelined `Consumer`.
2. First chunk is served with `CANCEL_CAPABLE`.
3. Next pipelined request for EOF starts before the first chunk is consumed.
4. `consume()` fails, causing the receiver to send normal cancellation.
5. Cancellation finalizes receiver status as `failed`.
6. The pipelined EOF resumes and publishes terminal source progress `completed` because `_handle_download()` falls back to producer EOF status when `obj_served()` returns no nonce for an already-final receiver.

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 1 triggered it; Level 0 did not in this run.
2. Level 2/3 injection or source patch used? **not applicable**.
3. Real consumer/caller observing the wrong outcome: source-side `progress_cb` via `nvflare/fuel/f3/streaming/obj_downloader.py:65` / `:71`; `ViaDownloaderDecomposer._make_result_upload_progress_cb` also forwards source progress at `nvflare/fuel/utils/fobs/decomposers/via_downloader.py:696`.
4. Permanence/masking: the bad source-progress stream is permanent for that callback invocation (`completed` is terminal and no later source `failed` appears). The final `TransferOutcome` remains `failed`, so waiter-based send success is masked by outcome computation, but the reported progress surface is still wrong.

## Developer intent
The current receiver-confirmed contract distinguishes producer-served EOF from confirmed receiver success. `compute_transfer_outcome()` also treats failed receiver status as failed transfer outcome. Existing tests cover failed receiver confirmation and in-flight cancellation drains, which supports the intended rule that receiver truth wins over producer terminal progress when confirmation is enabled.

## Reproduction result
Reproduction test written and executed:

`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugMC-2_pipelined_eof_cancel_progress.py`

Command:

```bash
timeout 2m python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugMC-2_pipelined_eof_cancel_progress.py
```

Output:

```text
Level 0 attempt: public download/cancel path, no timing gates
  source_states=['active', 'active', 'failed']
  outcome_status=failed receiver_statuses={'receiver1': 'failed'}
Level 1 attempt: same path with callback/event timing gates
  requests=[{'ref_id': 'ref1', 'confirm_capable': True}, {'ref_id': 'ref1', 'confirm_capable': True, 'state': {'chunk_idx': 1}}]
  control_messages=[{'ref_id': 'ref1', 'cancel': True}]
  source_states=['active', 'active', 'completed']
  receiver_states=['start', 'failed']
  downloaded_to_one_calls=[('receiver1', 'failed')]
  outcome=failed reason=receiver_failed receiver_statuses={'receiver1': 'failed'}
  consumer_failed_reason='exception when consuming data: OSError: ENOSPC while storing streamed chunk'
  source_released=True
BUG TRIGGERED: source progress ended as completed while receiver truth/outcome ended failed
```

## Recommendation
Change `_handle_download()` so `expect_confirm=True` with `obj_served(...) is None` because the receiver is already final does not emit terminal source progress from producer EOF/ERROR. Return a structured result or final receiver status from `obj_served()`, then either suppress terminal source progress for already-final receiver-confirmed requests or emit the receiver-final status so cancellation’s `FAILED` remains the terminal source truth.

---

## Entry 3: Caller receiver declarations can diverge from complete-payload outcome semantics

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/fuel/f3/cellnet/cell.py:344

## Description
`Cell._fire_and_forget` encodes a stream payload once without passing `num_receivers` or `receiver_ids`, unlike `_broadcast_request`, which declares the direct broadcast targets. `ViaDownloader` then defaults the producer-side `DownloadService` transaction to one receiver, so one successful receiver can mark the two-target payload `COMPLETED`, run source release, and leave the second target unable to materialize the ref.

## Trigger scenario
A caller sends a stream-channel `cell.fire_and_forget(...)` message with a ViaDownloader-backed payload to `["receiver-a", "receiver-b"]`. `receiver-a` materializes first; `receiver-b` has not pulled yet. The transaction completes after `receiver-a` because it was created as `num_receivers=1, receiver_ids=None`, then `receiver-b` later fails with `invalid_request`.

## Developer intent
The intended payload-layer contract is strict all-expected-receiver completion: PRs such as [#4865](https://github.com/NVIDIA/NVFlare/pull/4865) introduced `COMPLETED` only when every expected receiver of every ref succeeded, while [#4736](https://github.com/NVIDIA/NVFlare/pull/4736) and [#5179](https://github.com/NVIDIA/NVFlare/pull/5179) are related but do not report this exact `_fire_and_forget` fanout metadata omission. GitHub issue/PR API search and local git history found no existing report for this mechanism.

## Reproduction result
Repro written and executed: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugCR-2_fire_forget_fanout.py`

Command:
```text
timeout 2m env PYTHONUNBUFFERED=1 /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugCR-2_fire_forget_fanout.py
```

Output:
```text
send_result={'receiver-a': '', 'receiver-b': ''}
sent_targets=['receiver-a', 'receiver-b']
tx_id=Ta5d17b94-4bb7-4d50-bb55-6d2b09ee253a ref_id=8d3c9c5d-507d-4fb6-9e64-82f134dadd5b
tx_num_receivers=1 tx_receiver_ids=None
after_receiver_a outcome_completed=True outcome_reason=all_receivers_succeeded outcome_num_receivers=1 outcome_receiver_ids=None outcome_ref_statuses={'receiver-a': 'success'}
source_lifetime released=True downloaded_to_all_calls=1 transaction_done_calls=[('Ta5d17b94-4bb7-4d50-bb55-6d2b09ee253a', 'finished')]
live_ref_after_receiver_a=None
finished_ref_statuses={'receiver-a': 'success'}
no ref found for 8d3c9c5d-507d-4fb6-9e64-82f134dadd5b from receiver-b
failed to download from source for source {'fqcn': 'source', 'ref_id': '8d3c9c5d-507d-4fb6-9e64-82f134dadd5b'}: error requesting data from source after 0.00010347366333007812 secs: invalid_request
receiver_b_failed=error requesting data from source after 0.00010347366333007812 secs: invalid_request
receiver_b_decode_error=failed to download from source
CR-2 reproduced: one receiver completed a two-target fire_and_forget payload and retired the source
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 public `Cell.fire_and_forget` plus normal FOBS/ViaDownloader/download APIs; only the network transport was in-process.
2. Level 2/3 used? Not applicable; no state injection or source patch.
3. Real consumer/caller observing wrong outcome: `TransferWaiter.wait()` at `nvflare/fuel/f3/streaming/download_service.py:1128` observes `COMPLETED`; `download_object()` at `nvflare/fuel/f3/streaming/download_service.py:2074` for `receiver-b` observes `invalid_request`.
4. Permanent or masked? Permanent for this transfer attempt. The ref is no longer live, the tombstone only records `receiver-a`, and no resend/sync/guard later resolves `receiver-b`.

## Recommendation
Make `_fire_and_forget` mirror direct broadcast metadata: normalize `targets` before encoding and pass `num_receivers=len(targets)` plus `receiver_ids=targets` for non-pass-through direct fanout. Add a regression test covering multi-target stream `fire_and_forget` with a ViaDownloader payload where only one target completes first.

---

## Entry 4: Receiver budget diagnostics and activity clocks remain review-only

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/fuel/f3/streaming/download_service.py:762

## Description
`_Transaction.__init__` warns that `receiver_idle_timeout >= timeout` means “the budget can never fire and is effectively disabled.” That diagnostic is false: the transaction timeout is a sliding transaction-wide inactivity clock refreshed by any receiver, while receiver idle budget enforcement is per receiver and runs before transaction timeout retirement.

This is a reproduced diagnostic/configuration bug, not a transfer-outcome corruption bug. The final `TransferOutcome` correctly reports the stalled receiver as failed.

## Trigger scenario
Create a transaction with `timeout=10.0`, `receiver_idle_timeout=10.0`, and receivers `active` and `stalled`. `stalled` pulls once and stops. `active` pulls again at `t+9`, keeping the transaction-wide inactivity age below the 10s timeout. At `t+11`, the monitor fails `stalled` by idle budget while the transaction remains live.

## Developer intent
PR #4865 introduced the feature and states receiver budgets are opt-in, receiver stalls should be bounded by idle budget, and transaction timeout remains the backstop: https://github.com/NVIDIA/NVFlare/pull/4865. Existing `receiver_budget_test.py:395-405` pins the warning text, but only checks warning emission, not the multi-receiver sliding-clock schedule. Issue/PR searches for this exact mechanism found no existing report or fix.

## Reproduction result
Test written and executed: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugCR-4_receiver_budget_warning.py`

Command:
```bash
timeout 5m python3 /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugCR-4_receiver_budget_warning.py
```

Output:
```text
LEVEL0_WARNING='tx Tf640d77c-820a-497b-8ea0-d149b615ae76: receiver_idle_timeout=10.0s >= transaction timeout=10.0s -- the budget can never fire and is effectively disabled'
INITIAL_PULLS stalled=ok active=ok active_state={'chunk_idx': 1}
ACTIVE_REFRESH_AT_T_PLUS_9 status=ok active_state={'chunk_idx': 2}
TX_INACTIVITY_AT_T_PLUS_11=2.0s
LEVEL1_STATUSES_AFTER_BUDGET={'stalled': 'failed'}
TX_STILL_LIVE_AFTER_BUDGET=True
ACTIVE_FINISH_PULL status=ok active_state={'chunk_idx': 3}
ACTIVE_FINISH_PULL status=eof active_state=None
FINAL_OUTCOME_COMPLETED=False
FINAL_OUTCOME_REASON=receiver_failed
FINAL_OUTCOME_STATUSES={'stalled': 'failed', 'active': 'success'}
RESULT=DIAGNOSTIC_REPRODUCED_TRANSFER_OUTCOME_CORRECT
```

Checklist:
1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0 emitted the bad warning; Level 1 timing help confirmed the warning is false through normal request handling and monitor enforcement.
2. Level 2/3 injection or source patch used? **no**.
3. Real consumer/caller observing wrong outcome: `ObjectDownloader.__init__` at `nvflare/fuel/f3/streaming/obj_downloader.py:65` and direct `DownloadService.new_transaction` callers observe the misleading warning emitted at `download_service.py:764-767`.
4. Permanent or masked? The wrong diagnostic is permanent in logs and is not corrected downstream. The transfer outcome itself is correct, so transfer-semantic harm is not reproduced.

## Recommendation
Replace the warning/comment with clock-accurate text, or narrow the warning to only truly redundant configurations. Add a regression covering the multi-receiver case where another receiver refreshes transaction activity while the stalled receiver exceeds its idle budget.

---

## Entry 5: Receipt retention, acquired-receiver visibility and source-lifetime documentation residuals

- **Finding ID**: CR-5
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: nvflare/fuel/f3/streaming/download_service.py:1607

## Description
CR-5 does not reproduce as a live bug on the checked-out source. The runtime path records outcomes only after callbacks and source release attempts, final receiver truth remains available in `TransferOutcome`, same-id reuse clears expired receipts inline, and the CacheableObject issue is a stale/comment-level residual rather than a runtime lifetime failure.

The only oddity reproduced is a late waiter created after a time-compressed TTL but before an expiry query/monitor sweep receiving the still-present old receipt. I found no real high-level caller that creates such late post-TTL waiters; `CellClientAPI._wait_for_result_transfers()` uses waiters captured at transaction creation and validates the recorded outcome.

## Trigger scenario
Created real `DownloadService` transactions, drove normal producer-side download request handling to EOF/confirmation, waited on the public waiter facade, checked acquired receiver visibility before/after retirement, compressed receipt TTL to test an unswept expired receipt, and exercised `CacheableObject.transaction_done()`/`release()` behavior.

## Developer intent
PR #4865 documents the intended F3 payload contract: waiter outcomes are the “returns == delivered” primitive, settlement records after callback/source-release attempts, receipts are TTL-bounded, ids are attempt-scoped, and `acquired_receivers()` is the V1 acquired signal: https://github.com/NVIDIA/NVFlare/pull/4865

PR #5134 is a known fixed Client API waiter polling race, but it is a different mechanism from CR-5: https://github.com/NVIDIA/NVFlare/pull/5134

## Reproduction result
Test written and executed:
`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugCR-5_receipt_acquired_lifecycle.py`

Command:
```bash
timeout 5m python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugCR-5_receipt_acquired_lifecycle.py
```

Output:
```text
CR-5 reproduction attempt starting
worktree=/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/CR-5/worktree
LEVEL0 settle_then_record: waiter_returned_completed=True
LEVEL0 settle_then_record: callback_release_order=['transaction_done_cb', 'outcome_cb_released=False', 'release']
LEVEL0 settle_then_record: object_released_before_wait_return=True
LEVEL0 acquired_receivers: before_pull=[]
LEVEL0 acquired_receivers: after_first_pull=['r1']
LEVEL0 acquired_receivers: after_retirement=[]
LEVEL0 acquired_receivers: final_outcome_receivers=['r1']
LEVEL1 receipt_expiry: ttl_seconds=0.2
LEVEL1 receipt_expiry: late_waiter_before_query=COMPLETED
LEVEL1 receipt_expiry: get_transaction_outcome_after_same_age=None
LEVEL1 receipt_expiry: late_waiter_after_query=None
LEVEL1 receipt_expiry: late_waiter_after_monitor_sweep=None
LEVEL1 same_id_reuse: expired_receipt_removed_inline=True
LEVEL1 same_id_reuse: fresh_waiter_attaches_to_new_attempt=True
LEVEL0 cacheable_lifetime: transaction_done_clears_cache_only=True
LEVEL0 cacheable_lifetime: release_clears_base_obj=True
LEVEL0 cacheable_lifetime: post_release_get_item=RuntimeError
LEVEL2 state_injection: not used; public/timing paths reached the residual states
LEVEL3 source_patch: not used; source patching would manufacture a consequence
CR-5 reproduction attempt completed: no live wrong high-level caller outcome was triggered
```

## Recommendation
No runtime fix is justified from this confirmation. At most, clarify the `get_transfer_waiter()`/expired-receipt comment and the stale `CacheableObject._get_item()` comment so the documented lifetime matches the implemented live-only acquisition and explicit release behavior.

---
