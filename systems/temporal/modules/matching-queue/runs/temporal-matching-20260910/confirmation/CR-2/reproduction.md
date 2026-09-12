# CR-2 Reproduction

## Command

```sh
timeout 15m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro/test_bugCR-2_empty_interval.sh
```

Full captured output:

```text
/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-2/reproduction.out
```

## Result

- Level 0 public API control passed: `AddWorkflowTask` plus `PollWorkflowTaskQueue` delivered the persisted workflow task.
- Level 1 real bypass/stale-gap schedule passed: bypass delivered task IDs `[1 2]`; applying stale gap `1` left `read_level=2`, `ack_level=0`, and durable task IDs `[1 2]`.
- Level 2 diagnostic passed as a diagnostic only: an injected noncontractual `GetTasks` response with `tasks=0` and `next_page_token=true` made `getTaskBatch` ignore the token, `setReadLevelAfterGap` advanced `read_level=1` and `ack_level=1`, and the durable task ID `[1]` remained undelivered. This shows what would happen if such a backend response were possible, but the injected response itself is not a reachable public/API/backend state.
- SQLite selected-backend probe passed: pages were `[1]`, `[2]`, `[3]`; every nonterminal page had one task and the final page had no token, so `empty_nonterminal_page=false`.
- Cassandra live probe was not executed because no listener was available on `127.0.0.1:9042` and no local `cassandra:5.0` image was available. Static schema/code inspection did not find a current-schema route to the "static column record returned" branch for task reads.

## Decision

The code-review finding is not reproduced. The ordinary read/bypass/stale-gap path is guarded, and the exact harmful empty-interval proof requires a fabricated `GetTasks` response for the selected backend. The SQLite backend did not emit the empty nonterminal page. Cassandra remains live-environment-unprobed here, but current schema/source inspection makes the hypothesized static-row mechanism non-reachable in this revision.
