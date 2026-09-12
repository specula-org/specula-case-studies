# Fairness late-completion diagnostic — code-origin candidate CR-4

The previously proposed S5 / MC-5 source candidate was reproduced at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` using the real fair backlog reader/writer and file-backed SQLite SQL TaskStore V2. This is an implementation-level controlled diagnostic, not a new model-checking discovery or an independent Phase 4/public-API confirmation.

Evidence: [namespace-RPS reproduction](output/continuation-20260911/fairness/rps-reproduction.json), [log](output/continuation-20260911/fairness/rps-reproduction.log), [window-closed control](output/continuation-20260911/fairness/window-control.json), [control log](output/continuation-20260911/fairness/window-control.log). The corresponding SQLite files and [Go diagnostic](/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching/service/matching/specula_fair_diagnostic_test.go) are retained; use the absolute source path from the reproduction commands below.

## Observed mechanism and impact

1. A(1000,1), B(2000,2), C(3000,3) are durably spooled and handed to controlled poller interfaces. C receives a namespace RPS no-start rejection. Its completion passes the outstanding-membership check and releases the reader lock before re-spooling.
2. While that callback is paused, successful writes of fresh-key Y(1000,4) and Z(1000,5) evict B and C. The reader now tracks A/Y/Z with loaded=3. B's separately confirmed no-start callback sees its entry absent and returns without replacement, relying on later readback.
3. C's replacement commits as (4000,6), preserving C's namespace/workflow/run/event/stamp identity. The resumed C callback inserts an ack at the evicted old level and decrements loaded: **loaded=2 while three live entries remain**. Neither writer pin nor buffered writes is active at this point.
4. Completing A/Y/Z drives loaded to -1 and ack to **(3000,3)**, crossing B at **(2000,2)**. Real SyncState persists that boundary. B is still present in the independently read SQL rows, has no accepted History start or substitute in this diagnostic, and is absent from the real task-store query starting after the persisted ack. That query returns only C's replacement.

In the control, C finishes before Y/Z trim the queue. Loaded/live counts remain equal, persisted ack is (1000,6), and the restart-boundary query includes B. This isolates the unlocked callback/eviction window. The query exercises the actual restart boundary; this diagnostic does not launch a new full Matching service.

## Source basis

- `service/matching/fair_task_reader.go:153-207`: membership is checked before unlocking; successful re-spool is followed by relock and completeTaskLocked without another membership check.
- `fair_task_reader.go:210-220`: unconditional ack insertion and loaded decrement.
- `fair_task_reader.go:514-551`: merge evicts loaded entries, caches already-existing ack markers and retracts readLevel.
- `fair_task_reader.go:608-637`: advancing through leading ack markers can cross the now-absent B.
- `fair_task_writer.go:214-230`: write pin spans the transaction and write notification, then is released before the completion callback continues. The reproduction records pin=false and no buffered writes at late completion.
- `common/util.go:204-208,338-371`: namespace-scoped ResourceExhausted is not the system-scoped transient case used for same-record requeue; the selected error follows re-spooling.

A repair candidate is to recheck the original entry after re-spooling/reacquiring the reader lock, preserving loaded accounting and the gap left by eviction. No production repair was applied in this validation task.

## Exact scope

One unversioned root physical queue, fixed priority 3, fairness enabled, batch 3/reload 0, singleton writes, range size 16, exact map counter capacity 1000, dither disabled. GC threshold is 100 and metadata/GC timer intervals are one hour; SyncState is invoked explicitly. Matcher handoffs and History results are controlled interfaces; successful SpoolTask calls, pass assignment, write merging, callbacks, actual SQLite rows, metadata persistence and boundary queries execute real code. No task TTL expires during the run. General counter variants, weighted fairness and full end-to-end public APIs remain unvalidated.

Run from the source checkout after applying the harness:

```sh
SPECULA_FAIR_EVIDENCE=/absolute/output/reproduction.json timeout 180 /absolute/path/matching-fair-final.test -test.run '^TestSpeculaFairLateCompletionSQLite$' -test.count=1 -test.timeout=120s -test.v
SPECULA_FAIR_CONTROL=1 SPECULA_FAIR_EVIDENCE=/absolute/output/control.json timeout 180 /absolute/path/matching-fair-final.test -test.run '^TestSpeculaFairLateCompletionSQLite$' -test.count=1 -test.timeout=120s -test.v
```

The executable used here is `spec/output/continuation-20260911/matching-fair-final.test`; its source is `/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching/service/matching/specula_fair_diagnostic_test.go`. A present reproduction JSON plus a passing diagnostic means its explicit bug assertions succeeded. Independent confirmation/classification remains downstream. The ordinary fairness standing-backlog tests are separate fake-store diagnostics and do not replace this real-store result.
