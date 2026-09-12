# Confirmation Report — temporal-matching

## Final Result

Reproduced bugs: 1 = 1 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 3
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 1 reproduced + 0 env-limited + 0 masked + 3 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | FALSE POSITIVE | no |
| 2 | CR-2 | FALSE POSITIVE | no |
| 3 | CR-3 | FALSE POSITIVE | no |
| 4 | CR-4 | DROPPED | no |
| 5 | CR-5 | REPRODUCED | yes |

## Entry 1: Acceptance, uncertain persistence, and fresh ownership

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/matching/pri_task_writer.go:68

## Description

CR-1’s interleaving is reachable: task append, durable persistence, caller observation, reader signaling, and ownership reload are separate effects. But the reproduced implementation paths did not produce lost accepted work or a wrong worker-visible outcome. Committed-but-uncertain work remains either durable and replayable, deliverable to a worker, safely retryable, or rejected by owner-range fencing; duplicate delivery is absorbed by History’s `TaskAlreadyStarted` handling.

## Trigger scenario

I exercised normal add/poll, lost post-commit response, append during shutdown, fresh owner takeover, and stale-owner replacement fencing against the real matching path and SQLite persistence. Level 0/1 timing plus Level 2 controlled response loss were sufficient to reach the candidate preconditions. Level 3 source patching was not used because it would fabricate a different symptom after the reachable paths showed no bad state.

## Developer intent

The code intentionally treats ambiguous write errors conservatively in `writeDefinitelyFailed`, advances owner range on takeover, reloads up to prior allocation bounds, and lets History reject duplicate or obsolete workflow task starts. I also searched upstream issues and recently closed PRs for this exact mechanism. Related fixes existed for buffered writer channels, bypass reader/read-level handling, and read/ack regression, but I found no prior report for this acceptance plus uncertain persistence plus fresh-ownership loss mechanism: https://github.com/temporalio/temporal/pull/10848, https://github.com/temporalio/temporal/pull/11570, https://github.com/temporalio/temporal/pull/9841.

## Reproduction result

Repro test written and executed: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro/test_bugCR-1_acceptance_ownership.sh`

```text
go_test_exit=0
--- PASS: TestSpeculaMatchingNormal (0.10s)
--- PASS: TestSpeculaMatchingUncertain (0.10s)
--- PASS: TestSpeculaMatchingReplacementFencing (0.31s)
--- PASS: TestSpeculaMatchingAppendShutdown (0.20s)
--- PASS: TestSpeculaMatchingInsertionAfterStop (0.20s)
PASS
ok  	go.temporal.io/server/service/matching	2.705s

TRACE uncertain-write
  events={"AddTaskReply": 1, "AddTaskReplyLost": 1, "CreateTasksCommit": 2, "CreateTasksUncertainReturn": 1, "GetTasksSnapshot": 1, "PollTaskQueueResponse": 1, "RecordTaskStarted": 2, "TakeOverTaskQueueBegin": 1, "TraceEnd": 1, "UpdateTaskQueueCommit": 2}
  durable_end={"ack": 2, "range": 2, "rows": []}
  history_worker_true=1 starts=[1] obsolete=0 expired=0
  calls=[{"buffer": "unknown", "pc": "done", "receipt": "error", "response": "error"}, {"buffer": "ok", "pc": "done", "receipt": "lost", "response": "ok"}]

TRACE append-shutdown
  events={"AddTaskReply": 1, "AppendTaskShutdown": 1, "CreateTasksConditionFailed": 1, "GetTasksSnapshot": 1, "TakeOverTaskQueueBegin": 1, "TraceEnd": 1, "UpdateTaskQueueCommit": 2}
  durable_end={"ack": 2, "range": 2, "rows": []}
  history_worker_true=0 starts=[] obsolete=0 expired=0
  calls=[{"buffer": "condition", "pc": "done", "receipt": "error", "response": "error"}]

TRACE insertion-after-stop
  events={"AddTaskReply": 1, "AppendTaskShutdown": 1, "CreateTasksCommit": 1, "GetTasksSnapshot": 1, "PollTaskQueueResponse": 1, "RecordTaskStarted": 1, "TakeOverTaskQueueBegin": 1, "TraceEnd": 1, "UpdateTaskQueueCommit": 3}
  durable_end={"ack": 1, "range": 2, "rows": [1]}
  history_worker_true=1 starts=[1] obsolete=0 expired=0
  calls=[{"buffer": "ok", "pc": "done", "receipt": "error", "response": "error"}]

TRACE replacement-fencing
  events={"AddTaskReply": 1, "CreateTasksCommit": 1, "CreateTasksConditionFailed": 1, "GetTasksSnapshot": 1, "PollTaskQueueResponse": 1, "RecordTaskStarted": 1, "RecordTaskStartedError": 1, "TakeOverTaskQueueBegin": 2, "TraceEnd": 1, "UpdateTaskQueueCommit": 2}
  durable_end={"ack": 0, "range": 3, "rows": [1]}
  history_worker_true=1 starts=[2] obsolete=0 expired=0
  calls=[{"buffer": "ok", "pc": "done", "receipt": "ok", "response": "ok"}]
```

## Recommendation

Do not file CR-1 as a Temporal bug. Keep the repro as a regression/contract test if useful, and update the model or review note to account for range fencing, durable reload, conservative uncertain-write handling, and History duplicate-start rejection.

---

## Entry 2: Read snapshots, bypass, and proof of an empty interval

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/matching/pri_task_reader.go:247

## Description

CR-2 does not reproduce on the executed priority matching path. The risky code shape is real: `priTaskReader.getTaskBatch` only checks `len(response.Tasks)` and ignores `NextPageToken`, so an empty page with a continuation token would be treated as proof of an empty interval. But the reachable paths I tested do not produce that precondition.

The normal read/bypass race is guarded by `signalNewTasks` and `setReadLevelAfterGap`; the selected SQLite task store also did not emit an empty nonterminal page. Cassandra was not live-probed in this environment, but current schema/source inspection did not show a reachable static-row path for task reads.

## Trigger scenario

Test written and executed:

`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro/test_bugCR-2_empty_interval.sh`

It covers:

Level 0: real `AddWorkflowTask` plus `PollWorkflowTaskQueue`, delivered normally.

Level 1: real priority-reader bypass response followed by a stale gap; stale gap was ignored and both tasks remained delivered/durable.

Level 2: injected `GetTasks{Tasks:0, NextPageToken:true}` diagnostic showed the reader would skip if that backend response existed, but that precondition was fabricated and not reached by public API or selected backend.

## Developer intent

The comments at `service/matching/pri_task_reader.go:402` say read level must not advance past IDs that can reach the DB. The stale-gap guard at `service/matching/pri_task_reader.go:508` implements that intent for bypass/read races. Related upstream PRs were checked: [#9841](https://github.com/temporalio/temporal/pull/9841), [#11047](https://github.com/temporalio/temporal/pull/11047), [#11570](https://github.com/temporalio/temporal/pull/11570), and [#11917](https://github.com/temporalio/temporal/pull/11917). None reports the exact empty-nonterminal-page mechanism, so novelty is `NEW`.

## Reproduction result

```text
CR2_REPRO: head=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
LEVEL0_RESULT: public AddWorkflowTask/PollWorkflowTaskQueue delivered scheduled_event_id=11 workflow_id=bug-cr2-workflow
--- PASS: TestBugCR2Level0PublicWorkflowAddPollNoSkip

LEVEL1_RESULT: bypass_deliveries=2 read_before_gap=2 ack_before_gap=0 stale_gap=1 read_after_gap=2 ack_after_gap=0 durable_task_ids=[1 2]
--- PASS: TestBugCR2Level1RealBypassStaleGapSafety

LEVEL2_INJECTION: returned tasks=0 next_page_token=true min=1 max=2 page_size=1000
LEVEL2_DIAGNOSTIC: getTaskBatch tasks=0 read_level=1 batch_done=true token_was_ignored=true
LEVEL2_DIAGNOSTIC: after_gap read_level=1 ack_level=1 captured_deliveries=0 durable_task_ids=[1]
--- PASS: TestBugCR2Level2InjectedEmptyNonterminalPageDiagnostic

SQLITE_PAGE: page=1 tasks=1 next_page_token=true ids=[1]
SQLITE_PAGE: page=2 tasks=1 next_page_token=true ids=[2]
SQLITE_PAGE: page=3 tasks=1 next_page_token=false ids=[3]
SQLITE_PROBE: pages=3 got_tasks=3 empty_nonterminal_page=false
--- PASS: TestBugCR2SQLiteNoEmptyNonterminalTaskPage

CASSANDRA_PROBE: skipped; no listener on 127.0.0.1:9042
CASSANDRA_PROBE: no local cassandra:5.0 image available
CR2_REPRO_DONE
```

## Recommendation

Do not file CR-2 as reproduced. If this area is hardened later, the narrow improvement would be to assert/log that `GetTasks` never returns `Tasks == 0 && NextPageToken != nil`, but the confirmation evidence does not show a reachable correctness bug on the selected backend.

---

## Entry 3: Completion prefix, delayed metadata, and old-owner cleanup

- **Finding ID**: CR-3
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/matching/pri_task_reader.go:597

## Description
CR-3 does not reproduce as a bug. The tested interleaving is real: the old owner can GC below an in-memory ack-derived bound while its final metadata sync later loses the range-ID check. But the rows deleted by GC were already consumed: History accepted both task starts and the workers received both poll responses before deletion. I found no caller-visible lost required work.

## Trigger scenario
The repro exercised the candidate sequence with the real matching priority backlog path: enqueue two workflow tasks, poll both, hold old-owner GC, hold old-owner metadata sync, replace ownership, release GC first, then release stale metadata sync. The stale sync failed with `actualRange=2, expectedRange=1`, and the new owner read no remaining rows.

## Developer intent
The implementation intentionally advances ack when a priority queue is drained and intentionally skips/folds metadata writes for performance while using range-ID checks to detect ownership loss. Related Temporal PRs include #9731, #9739, #10018, and #11570, but I found no upstream issue or recently merged/closed PR for this exact stale-metadata plus old-owner-GC mechanism.

## Reproduction result
Executed `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro/test_bugCR-3_metadata_gc.sh`.

```text
CR-3 reproduction test
worktree=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
=== RUN   TestSpeculaMatchingNormal
--- PASS: TestSpeculaMatchingNormal (0.49s)
=== RUN   TestSpeculaMatchingMetadataGC
--- PASS: TestSpeculaMatchingMetadataGC (0.44s)
PASS
ok  	go.temporal.io/server/service/matching	0.957s

CR-3 parsed evidence
level0=TestSpeculaMatchingNormal passed with public AddWorkflowTask/PollWorkflowTaskQueue and no staged owner replacement
level1=TestSpeculaMatchingMetadataGC passed with timing gates for old-owner GC, stale metadata sync, and owner replacement
record_started_count=2
worker_response_count=2
old_owner_delete={"seq":52,"node":1,"args":{"deleted":[{"id":1,...},{"id":2,...}],"limit":2,"max":3,"o":1},"post":{"durable":{"ack":0,"range":2,"rows":[]}}}
old_owner_stale_sync={"seq":54,"node":1,"args":{"actualRange":2,"expectedRange":1,"o":1}}
new_owner_read_after_delete={"seq":66,"node":2,"args":{"limit":3,"max":3,"min":1,"o":2,"tasks":[]}}
final_state={"seq":76,"event":"TraceEnd","post":{"durable":{"ack":2,"range":2,"rows":[]},"history":{...},"dispatch":[{"id":1,"owner":1,"reply":"ok","result":"ok"},{"id":2,"owner":1,"reply":"ok","result":"ok"}]}}
result=no caller-visible lost required work: deleted task rows had History start and worker response before GC; new owner found no rows and ended with empty backlog
```

## Recommendation
Do not file this as a confirmed bug. If the model keeps this scenario, refine the invariant so GC safety is judged against required work identity after History start and worker delivery, not against durable metadata ack alone.

---

## Entry 4: History outcomes and replacement before original acknowledgement

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/temporalio/temporal/issues/11733; fix-status: unfixed)
- **Location**: service/matching/matching_engine.go:3520

## Description
CR-4 duplicates Temporal issue #11733: an ambiguous `RecordWorkflowTaskStarted` / `RecordActivityTaskStarted` timeout can leave History with a committed task start while Matching later retries via a fresh `RequestId`, causing History to return `TaskAlreadyStarted` and leaving no worker with the committed response.

## Trigger scenario
Match a workflow/activity task to an active worker poll, let History commit `Record*TaskStarted`, delay/lost-return the response until Matching’s shorter child context expires, then let Matching retry later with a different `RequestId`.

## Developer intent
History’s same-request duplicate handling is intentionally idempotent, while different-request duplicate starts return `TaskAlreadyStarted`. Open PR #11734 proposes keeping the same request id across attempt-local deadlines while the original worker poll remains active.

## Reproduction result
Dropped before Phase 2 per the skill’s code-review x known pre-filter. I updated the finding-local `investigation.md` and `verdict.json`; no CR-4 repro test was written.

```text
gh issue view 11733 ... -> state OPEN, title "Task start can remain undelivered after an ambiguous History timeout"
gh pr view 11734 ... -> state OPEN, mergedAt null, title "Retry ambiguous task starts for active worker polls"
```

## Recommendation
Do not count CR-4 as a new confirmed Specula bug. Record it as known/unfixed and cite upstream issue #11733 plus open PR #11734.

---

## Entry 5: Fairness eviction during unlocked replacement

- **Finding ID**: CR-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: service/matching/fair_task_reader.go:153

## Description
Confirmed. In `fairTaskReader.completeTask`, the error path verifies that a task is still tracked, releases `tr.lock` for `respoolTaskAfterError`, then later calls `completeTaskLocked` without rechecking membership. During that unlocked replacement window, fair write merges can evict live tasks; the resumed completion can insert an ack marker that lets durable `FairAckLevel` cross an evicted, still-eligible task.

## Trigger scenario
`C` receives a non-BUSY `ResourceExhausted` History-start error and enters the replacement path. While `C` is paused after the membership check but before replacement completion, fresh lower-fair-level writes `Y/Z` are accepted and evict live `B/C`. `B` then completes missing and is not acked; `C` resumes and inserts an old-level ack. After `A/Y/Z` complete, durable ack reaches `<3000,3>`, crossing `B=<2000,2>`.

## Developer intent
Nearby comments say missing completed tasks should not be acked and should eventually be re-read as duplicates. Existing PRs cover adjacent fair-reader races and evicted ack handling (#8093, #9234, #10851, #11048), but issue/PR/git-history searches found no existing report for this exact re-spool-after-unlocked-replacement mechanism.

## Reproduction result
Test written and executed:  
`/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro/test_bugCR-5_fairness_eviction.sh`

Command:
```bash
timeout 10m /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/repro/test_bugCR-5_fairness_eviction.sh
```

Key output:
```text
revision=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025

== level0_control ==
level0_control: reproduced=False
level0_control: durableAck=<1000,6>
level0_control: BLevel=<2000,2>
level0_control: ackCrossesB=False
level0_control: BRowsInStore=1
level0_control: BReturnedByRestartRead=True

== level1_candidate ==
failed assertion: loadedTasks went negative
go.temporal.io/server/service/matching.(*fairTaskReader).completeTaskLocked
  .../service/matching/fair_task_reader.go:216
level1_candidate: reproduced=True
level1_candidate: durableAck=<3000,3>
level1_candidate: BLevel=<2000,2>
level1_candidate: ackCrossesB=True
level1_candidate: BRowsInStore=1
level1_candidate: BReturnedByRestartRead=False
```

Checklist:
1. Level 1 triggered it: yes, with timing assistance at the unlocked replacement window; no Level 2 state injection and no logic-altering source patch by this repro.
2. Not applicable.
3. The real consumer is the fair reader’s restart/read path, `service/matching/fair_task_reader.go:285`, via `db.GetFairTasks` at `service/matching/db.go:731`; it starts from persisted ack+1 and no longer observes `B`.
4. The bad state is permanent for that reader boundary: `B` remains in SQLite, but persisted `FairAckLevel=<3000,3>` is past `B=<2000,2>`, so reload-style reads skip it. No downstream sync/resend/guard masked it in the reproduction.

## Recommendation
Recheck membership after `respoolTaskAfterError` returns, before calling `completeTaskLocked`, and treat an evicted/missing old task like the initial missing-completion case. Also guard `completeTaskLocked` against decrementing `loadedTasks` for a task that is no longer live in `outstandingTasks`.

---
