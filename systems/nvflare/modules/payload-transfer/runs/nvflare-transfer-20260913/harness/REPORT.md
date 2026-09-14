# Harness execution evidence

End-to-end run passed: 16 runtime traces, 3,029 events, all 94 modeled event types, 16 complete original-spec replays, 11 separate profile/regression tests, and three expected validator rejections.

Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. The supplied base/Trace specifications and invariant checks are unchanged. Final machine receipts are `logs/audit.json`, `logs/test-results.json`, `logs/validation-results.json`, `logs/coverage.json`, `logs/negative-controls.json`, and `logs/build.json`. `logs/end-to-end.log` records the one-command run.

This phase collects and checks implementation traces. It does not run the MC hunt configurations, prove general safety/liveness, classify a production defect, or establish real resource-exhaustion reachability.

## Main corpus

All main scenarios use two registered refs, two explicit receiver identities (`site-a`, `site-b`), confirmation enabled at both endpoints, a pipelining-capable Consumer, one ordinary one-byte DATA chunk, and real Cell/DownloadService/Consumer methods. Registration is complete before payload exposure. Each scenario is a separate pytest process and raw NDJSON file.

| Scenario | Exercised observation |
|---|---|
| `confirmed_success` | EOF remains provisional while `download_completed` is blocked; all receiver confirmations produce strict success. Concurrent receivers/refs, callback/release ordering, late waiter and receipt expiry are observed. |
| `receiver_failure_and_callbacks` | One completion callback raises; strict success fails while one common successful receiver still meets quorum. Independent one/all/object/transaction/outcome/release Exceptions do not skip sibling cleanup or waiter resolution. |
| `disjoint_receivers_and_idle_budget` | Opposite receivers hold different refs. At exactly the idle budget no expiry occurs; after it, missing sibling outcomes become FAILED. FINISHED is true, completed and quorum are false. |
| `active_receiver_and_stalled_sibling` | Receiver B's current request refreshes its own and global activity; receiver A's untouched sibling still expires. Healthy B remains provisional until its completion returns. |
| `never_acquired_receiver` | A succeeds on both refs; B never starts and fails its acquisition budget. A second pending waiter receives the same recorded outcome. |
| `pipeline_consume_failure` | Next pull is already admitted when consume fails. Cancellation finalizes that receiver across both refs; the admitted operation remains counted until its actual return. |
| `delete_with_late_confirmation` | Deletion settles while Consumer completion is blocked. The later confirmation is dropped; a supported late first acquisition observes a missing ref. The stored outcome remains unchanged. |
| `shutdown_pending_waiter` | Shutdown resolves the waiter to terminal None, clears ownership, then runs cleanup. Later confirmation is dropped; the actual caller rejects None. |
| `transaction_timeout` | Receiver budgets disabled; the sliding transaction timeout uses strict greater-than and produces a failed timeout outcome. |
| `producer_error` | Ordinary terminal ERROR carries the serve nonce; Consumer sends FAILED truth without calling successful completion. |
| `producer_exception` | Ordinary produce exception causes PROCESS_EXCEPTION; the real Consumer takes the cancellation path and fails sibling refs. |
| `bounded_drain_and_late_cancel` | Deletion's 2-second fixture drain expires with an admitted pull blocked. Cleanup/receipt finish while its termination marker remains. Later cancel is dropped; operation exit and actual reap clear the marker. |
| `lost_confirmation` | A local transport send raises for A's confirmations. Actual send failure is recorded; idle budgets provide final producer-side FAILED outcomes. B's whole payload still meets quorum. |
| `executor_stopped_fallback` | A dedicated real CheckedExecutor is stopped; submit returns None and the real inline fallback completes settlement. |
| `queue_then_submit_exception` | A dedicated executor's real work item is enqueued, then injected `_adjust_thread_count` RuntimeError selects inline fallback. A later ordinary submission starts a real worker that consumes the existing queued item. Two callback/release chains and one receipt write are observed. |
| `outcome_computation_exception` | A locally injected computation exception invokes the implementation's actual fail-closed verdict construction, cleanup, outcome callback and recording. |

The queue scenario is a **controlled fault-injection trace**. It establishes what this implementation does after that injected submit failure; it does not establish spontaneous production triggering. No resource exhaustion is induced. The normal and stopped paths use the same real CheckedExecutor implementation; no copied stdlib or alternate settlement implementation is used.

## Priority questions and evidence boundaries

1. **Terminal serving versus receiver success:** the normal scenario observes pending/provisional status and an unresolved waiter while finalization is blocked. The failure scenario records actual FAILED confirmation after EOF. Legacy evidence below uses its own producer-served contract.
2. **Complete payload and quorum:** disjoint-receiver and partial-fan-out scenarios inspect actual `TransferOutcome`, not a model-recomputed verdict. FINISHED includes final receiver failures; completed requires all expected receiver/ref successes; quorum counts receivers successful across every ref. The minimal actual Client API barrier accepts only a non-None COMPLETED outcome.
3. **Overlapping termination:** cancellation with an in-flight pipeline operation, deletion/late confirmation, shutdown/late confirmation, timeout and bounded draining are recorded. Receipt ownership is single-write in all traces. Under the explicit queue failure injection, settlement effects repeat even though the receipt does not; these two observations must not be conflated.
4. **Activity scope:** the corpus checks exact budget boundaries, transaction-level activity for each receiver across sibling refs, and a healthy receiver alongside an expired one. Receiver activity and progress counters are different observations. No absolute transaction-age deadline is assumed.
5. **Callbacks, sources and waiters:** callback arguments include actual source identities and outcome values. `outcome_cb` runs before release attempts; receipt recording resolves waiters after that invocation's release attempts return. A release Exception can leave its source reference held while sibling cleanup and the waiter still finish. Shutdown terminal None occurs before cleanup. Receipt expiry preserves values already delivered to waiters.

## Separate profiles

`logs/profiles.log` records 11 passing tests: one real Cell metadata capture, four selected upstream legacy/disabled-confirmation tests, five upstream quorum tests, and the unknown receiver-count test. These are local regression/argument evidence, **not confirmed-mode trace conformance**.

`logs/caller-profiles.json` records actual `encode_payload` arguments while real Cells deliver six ordinary payloads:

- ordinary two-target broadcast supplies count 2 and both target identities;
- pass-through broadcast supplies count 2 without final receiver identities;
- two-target fire-and-forget supplies neither receiver count nor identities in this caller path.

This argument capture does not claim a large serialized payload produced a false successful receipt. The main trace profile must not be used to certify the fire-and-forget or count-only callers as explicit-identity transfers. The original pass-through E2E file uses real server/subprocess Cells but simulates the CJ hop; that suite was inspected for fixture reuse, not run or relabeled as full transfer-barrier coverage.

The selected upstream legacy tests confirm producer-served terminal status when confirmation is disabled or the peer does not advertise support. They do not assert that the receiver's final consumption succeeded. The minimal caller test invokes the real `CellClientAPI._wait_for_result_transfers` helper with a small caller object; full trainer publication/session management is outside this harness.

## Coverage limits

- Complete event-type coverage is not complete branch/interleaving coverage. In particular, all budget freshness-race outcomes, stopped-versus-queued future cancellation schedules, nonce retry/replacement, every retained tombstone TTL branch, concurrent per-ref snapshot changes, and all shutdown/submit acknowledgement orderings are not exhaustively explored.
- Main protocol execution uses real Cells in one process; their supported in-process routing can bypass TCP. Underlying byte transport correctness, scheduling fairness and network deployment behavior are not validated.
- The source is a supported test Downloadable/Consumer plugin. Its produce implementation reuses the upstream ordinary chunk fixture; source release is the plugin's real owned-reference mutation. CacheableObject internals, default no-op release, byte serialization and physical garbage collection are not exercised. The recorder and fixture retain observer/application aliases; `sourceHeld` means only the registered `base_obj` reference, as specified.
- Receiver counts/identities are exact and registration frozen in the main corpus. No late object registration, ref/transaction reuse, retries, duplicate control traffic, adversarial participants, hook reentrancy/mutation, process-level BaseException, whole trainer processes, HA or ML numerics are introduced.
- Negative controls are mutated copies under `harness/controls/`, explicitly excluded from the runtime corpus. Wrong post-state, missing required field and unknown event must fail `TraceMatched` in the original module. No state check, invariant or transition was weakened to obtain conformance.
