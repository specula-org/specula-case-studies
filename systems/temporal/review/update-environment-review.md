# Temporal Update CR-1 independent review

Finding reviewed: `CR-1`, originally `ENV_LIMITED`, “wrong Update outcome from stale host event cache”.

Pinned source under review: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.

Latest upstream snapshot checked: `9ab3a9f770da20df7d94bcc0030f28eec7b0b947`.

Isolated review workspace: `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env`.

## Independent verdict

`ENV_LIMITED` is valid as a finding, with a strict evidence boundary: this review establishes a sound production argument for a rare multi-history-host sequence and reproduces the wrong outcome at the state/cache boundary, but it does not reproduce the full public end-to-end wrong outcome in the local onebox harness.

I would not downgrade this to `FALSE_POSITIVE`: the missing `UpdateId` validation is real, the cache key collision is legal at the history-node layer, host-level caches are enabled by default, and shard loss/reacquisition does not clear the host cache. I would also not call it `REPRODUCED`: the public controls did not produce a wrong public `PollWorkflowExecutionUpdate` response, and the decisive A -> B -> A host-handoff schedule was not executed in this environment.

Assessments requested:

| Criterion | Assessment | Reason |
| --- | --- | --- |
| Real production reachability | Medium | The code supports the required sequence, including same eventID/version with a later winning txn and stale host cache survival; the full multi-host schedule was not run. |
| Severity | High | If the sequence occurs, a public Update poll can return Update A's completed outcome for Update B. That is a client-visible correctness violation. |
| Confidence | Medium | The vulnerable read path and state-level consequence are directly exercised; the full production interleaving remains argued from source rather than observed. |
| Maintainer fix likelihood | Medium | The local fix is narrow and defensible, but maintainers may ask for either a multi-host integration test or a focused unit test around cache mismatch handling. |

## Why the cache collision is production-legal

The core read bug is unchanged from the original report. `GetUpdateOutcome` first looks up durable `UpdateInfos[updateID]`, then fetches the completion event through `eventsCache.GetEvent` using only namespace/workflow/run/event ID/version. It only checks that the returned event is a `WorkflowExecutionUpdateCompleted` event; it does not compare the event's `Meta.UpdateId` with the requested update ID (`service/history/workflow/mutable_state_impl.go:1544-1588`). `writeEventToCache` uses the same key fields and does not include update ID (`service/history/workflow/mutable_state_impl.go:2086-2103`). On cache hit, `events.CacheImpl.GetEvent` returns the cached event immediately, before consulting the batch ID or branch token (`service/history/events/cache.go:110-124`).

The event ID reuse premise is also source-supported. During `UpdateWorkflowExecution`, SQL persistence appends history nodes before the RangeID-fenced mutable-state transaction (`common/persistence/sql/execution.go:334-357`). The append path itself sets only `request.ShardID` and calls `AppendHistoryNodes`; it has no RangeID fence (`service/history/shard/context_impl.go:871-908`). The RangeID check happens later inside `txExecuteShardLocked` and `readLockShard`, which returns `ShardOwnershipLostError` if another owner has advanced the shard range (`common/persistence/sql/execution.go:39-57`, `common/persistence/sql/shard.go:151-169`).

The two competing history batches can legally have the same event ID and version. SQL history rows are keyed by `(shard_id, tree_id, branch_id, node_id, txn_id)`, not just event/node ID (`schema/sqlite/v3/temporal/schema.sql:309-320`; the MySQL/PostgreSQL schemas use the same key shape). Temporal's own persistence comments say that for the same event ID, the node with the larger transaction ID wins (`common/persistence/persistence_interface.go:523-530`, `common/persistence/data_interfaces.go:784-791`). New event batches receive fresh task IDs as history-node transaction IDs (`service/history/workflow/mutable_state_impl.go:8585-8602`), and task IDs come from the shard RangeID-derived allocator (`service/history/shard/task_key_generator.go:151-184`). A later owner with a later range can therefore write a later transaction for the same first event ID without the stale earlier history node proving impossible.

The stale host can later reacquire while retaining its stale cache. Host-level event cache is enabled by default, with one-hour TTL and a large host-level capacity (`common/dynamicconfig/constants.go:1949-1963`). When enabled, a new shard context receives the shared host-level cache object rather than a fresh shard-level cache (`service/history/shard/context_impl.go:2258-2268`). `ShardOwnershipLostError` triggers shard stop, and ambiguous write errors can trigger reacquisition, but neither path clears the host-level event cache (`service/history/shard/context_impl.go:1475-1548`). The public history client redirects to the owner named in `ShardOwnershipLost` and updates its shard cache (`client/history/redirector.go:78-91`, `client/history/caching_redirector.go:105-132`, `client/history/caching_redirector.go:205-224`), so a poll can later be served by the reacquired stale host if it becomes the owner again.

The concrete production sequence supported by the source is:

1. Host A owns the shard and completes Update A. `ApplyWorkflowExecutionUpdateCompletedEvent` writes the Update A completion to the host event cache before persistence success (`service/history/workflow/mutable_state_impl.go:5852-5901`).
2. The write does not commit the execution mutation, for example because Host B advances shard ownership before A's later RangeID-fenced transaction. A's host-level cache still contains Update A at key `(namespace, workflow, run, eventID, version)`.
3. Because mutable state did not commit A's next-event advance, Host B can later commit Update B at the same event ID/version with a later history-node transaction ID. Durable `UpdateInfos[B]` then points to that event ID/batch.
4. Host A later reacquires the shard before the host cache entry expires or is evicted.
5. A `PollWorkflowExecutionUpdate` for B reaches Host A. `GetUpdateOutcome(B)` reads durable `UpdateInfos[B]`, but the host cache hit returns the stale Update A completion event under the same event key. Since the code does not compare `Meta.UpdateId`, the caller receives A's outcome for B.

This is a sound production argument for `ENV_LIMITED`; it is still a rare timing and routing sequence, not a one-host or ordinary retry path.

## Reproduction and controls

I first copied the existing reproduction tests into the isolated source clone, then added one narrow state-level test for the specific two-host cache divergence. I did not modify the original run artifacts or prior source checkout.

Reproduction script written for this review:

`/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/repro/run_cr1_review_tests.sh`

All test commands used `GOTOOLCHAIN=go1.27.0`, `GOMAXPROCS=8`, `go -p 4`, and an outer `timeout 10m`.

### Level 0 / public controls

Command:

```bash
GOTOOLCHAIN=go1.27.0 GOMAXPROCS=8 timeout 10m /usr/local/go/bin/go test -p 4 -tags test_dep ./cr1repro -run 'TestBugCR1(CommittedUpdateSurvivesLostCallerReceipt|OneHostNoncommittedCompletionDoesNotLeakToNextUpdate)$' -count=1 -v
```

Log:

`/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/cr1_public_controls_repro_script.log`

Observed:

- `CALLER_RECEIPT_LOST` followed by `RECOVERY_AFTER_LOST_RECEIPT`: a committed Update whose caller lost the response was later read back correctly.
- `FIRST_COMPLETION_ROLLED_BACK`, `READBACK_AFTER_ROLLBACK update_info_present=false next_event_id=5`: the first one-host failing completion did not leave durable update info.
- `SECOND_UPDATE_COMMITTED` followed by `SAME_HOST_RECOVERY_MASK`: in the one-host case, the later successful Update overwrote the cache slot before readback, so no wrong public outcome was observed.

This level does not reproduce the bug. It also explains why the old one-host harness is insufficient: it exercises the rollback/cache-write window, but same-host success overwrites the stale cache.

### Level 1 / fault-assisted control

The original public control uses Temporal's persistence fault injection. The `ResourceExhausted` fault used here is a runtime fault that returns before the underlying store operation executes, because `fault.execOp` defaults to false and only `ExecuteAndTimeout` sets it true (`common/persistence/faultinjection/fault.go:22-55`, `common/persistence/faultinjection/fault.go:61-72`, `common/persistence/faultinjection/execution_store_gen.go:250-255`). This validates in-memory cache write plus rollback behavior, but it does not by itself prove the SQL append-before-RangeID-loss path.

### Level 2 / state and cache-boundary reproduction

Command:

```bash
GOTOOLCHAIN=go1.27.0 GOMAXPROCS=8 timeout 10m /usr/local/go/bin/go test -p 4 -tags test_dep ./service/history/workflow -run 'TestBugCR1(GetUpdateOutcomeAcceptsCachedEventForDifferentUpdateID|HostLevelCacheDivergenceCanShadowCommittedUpdate)$' -count=1 -v
```

Log:

`/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/cr1_state_cache_plus_divergence_repro_script.log`

Observed markers:

```text
STALE_CACHE_RESULT requested_update_id=cr1-update-b cached_event_update_id=cr1-update-a observed=stale-result-from-cr1-update-a
HOST_CACHE_DIVERGENCE requested_update_id=cr1-update-b host_b_cached_update_id=cr1-update-b host_a_cached_update_id=cr1-update-a host_a_observed=stale-result-from-cr1-update-a
STATE_INJECTION_NOTE: this simulates two history hosts with independent host-level event caches; it does not prove the shard handoff timing through the public onebox harness
```

This level reproduces the wrong result once the real production precondition exists: durable mutable state says Update B completed at event ID N, while Host A's host-level cache still maps event ID N/version V to Update A. The test intentionally does not claim to be a full end-to-end production trigger.

### Level 3 / minimal code modification

Not attempted. The bounded review found enough source evidence for `ENV_LIMITED`, and the available `testcore` onebox harness explicitly requires exactly one service node per service (`tests/testcore/onebox.go:240-244`). Building a full multi-history-host integration harness was outside the requested time boundary.

## Latest-main and upstream context

The implicated paths are unchanged on latest upstream main `9ab3a9f770da20df7d94bcc0030f28eec7b0b947`, except unrelated dynamic-config edits recorded in:

`/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/latest_implicated_paths_diff.txt`

Open PR #11921, `d6cab79830c4ca7500ee532eb9b0cec51e57d21d`, is adjacent but not a fix for this mechanism. It changes Nexus Update handling for transient persistence-read failures and introduces `errUpdateNotFound` / `errUpdateNotComplete`; it still does not validate that the cached `WorkflowExecutionUpdateCompleted` event's `Meta.UpdateId` equals the requested update ID. See:

- `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/gh_pr_11921.json`
- `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/pr11921_mutable_state_diff.txt`

GitHub issue/PR searches found no public issue or PR describing this same stale event-cache Update outcome mechanism. The only nearby issue hit, #11600, is a different UpdateWithStart data race. Logs:

- `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/gh_issue_search_cr1_fixed.jsonl`
- `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/gh_pr_search_cr1_fixed.jsonl`
- `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-env/logs/gh_issue_11600.json`

Novelty assessment: `NEW`, no same-mechanism public issue/PR found; unfixed at latest checked main and PR #11921.

## Consequence and recovery

If the production sequence occurs, `PollWorkflowExecutionUpdate` for Update B can return Update A's completed outcome. The returned outcome could be a wrong success payload, wrong failure, or wrong cancellation/disposition. Durable state remains recoverable; the harm is the client-visible result served from cache.

Natural recovery or masking mechanisms:

- Same-host later completion overwrites the cache slot; the one-host public control observed this mask.
- Cache TTL expiry, cache eviction, process restart, or disabling host-level event cache removes the stale entry.
- Serving the poll from Host B or any cold/missing cache path loads from persistence and should return B's correct event.

Those recovery paths do not eliminate the bug because a client can consume the wrong outcome before recovery.

## Fix shape

The narrow fix is to validate update identity after loading a `WorkflowExecutionUpdateCompleted` event in `getUpdateOutcomeEvent`:

1. Read `attrs := event.GetWorkflowExecutionUpdateCompletedEventAttributes()`.
2. Preserve the existing nil/type check.
3. Compare `attrs.GetMeta().GetUpdateId()` with the requested `updateID`.
4. On mismatch, delete or ignore the cache entry and reload from persistence, or return an internal consistency error that forces retry through a safe path.

The important invariant is that the durable `UpdateInfo` lookup and the event returned from cache must agree on update ID. Adding this check is low-risk because a matching cached event preserves current fast-path behavior, while a mismatch is already internally inconsistent.
