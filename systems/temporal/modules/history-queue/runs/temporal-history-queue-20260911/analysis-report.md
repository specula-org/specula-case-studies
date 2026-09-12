# Code Analysis Report: temporal-history-queue

Pinned revision: **0c010ce5fe8c0180aa7573c72fe8fc87c6df7025**, temporalio/temporal. Source repository: `/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-history-queue`. Investigation and upstream refresh: **2026-09-11**. Primary handoff: [modeling-brief.md](modeling-brief.md).

## Result and evidence boundary

**One new source-review finding was reproduced at the native queue boundary: CR-1, checkpoint shrinking can detach a nondefault reader's cursor and leave later eligible-range tasks unread.** The retained task is physically present and remains represented in the durable checkpoint. Native reconstruction repairs the reader and allows later cleanup. This is a live-reader progress defect, not demonstrated data loss. The critical state was produced by the real move-group action at the production batch size100; the injected schedule controls ACK and checkpoint ordering.

The tests do not construct500 real pending workflow executions or reproduce an end-to-end stalled user workflow. They operate real queue/read/slice/checkpoint/store code with controlled executable ACKs. A separate healthy functional test traverses real Frontend, History, Matching and worker polling, completes a Workflow/Activity exchange, and checks the full11-event history. That control establishes ordinary executor outcomes but is not the same adversarial run.

**Model-checking discovery=0; model-checking reconfirmation=0; complete implementation-trace validation=0.** This turn completes the four phases of the requested **code-analysis** skill and its Spec Generation handoff. Later model, harness, trace-negative-control and bounded-search work is specified concretely in the brief, not reported as already executed. No TLC search was launched, so none is mislabeled as a completed or INCOMPLETE search. Overall coupled formal coverage remains **NOT RUN**.

Two additional source observations remain pending targeted verification: CR-2 duplicate-key merge accounting and CR-3 shard-checkpoint batching bookkeeping after semaphore failure. Neither is counted as a confirmed user-visible defect. Known upstream behavior, conservative recovery, fixed bugs, refuted causal reports and test limitations are retained below and in the complete audit appendices.

## Methodology and phase coverage

The user-selected skill was read in full at `/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/Specula/skills/code_analysis/SKILL.md`, including guide.md, references/deep-analysis.md, distributed-analysis.md, bug-archaeology.md, modeling-brief-format.md and the Hashicorp example. Category A was recorded before archaeology/deep investigation; BFT and Category B overlays do not apply. Repository AGENTS.md was read before local diagnostic test additions.

1. **Reconnaissance**: verified clean pinned checkout; mapped workflow transaction→allocation/pending writes→SQL rows→queue ranges/readers→executor/Matching→ACK→checkpoint/DELETE→reconstruction; identified locks, store transactions and asynchronous boundaries.
2. **Bug archaeology**: mined every keyword match in bounded core/current/predecessor pathspecs; added non-keyword semantic corrections; refreshed issues and all relevant open PRs. Three parallel reviewers handled publication, checkpoint and executor batches while the parent handled reader/slice/action analysis and the global upstream screen.
3. **Deep analysis**: complete production-core reading, exact-line rereads, both handoff sides, compensation and reachability checks; source review led to CR-1; native controlled tests with healthy and recovery controls established the observed queue consequence.
4. **Modeling brief**: five mechanism-based Scenarios, model/exclusion decisions, explicit variables and atomicity, safety/liveness properties and separate model/test/code-review queues. All five target questions are mapped to evidence and remaining gaps.

### Coverage denominators

| Evidence population | Count and meaning |
|---|---|
| Explicit current production core | **41 files /16,720 physical lines**, excluding tests/generated mocks; complete reads; `evidence/core-file-inventory.json`. Adjacent source functions/files were also read but not added to this denominator. |
| Reader/slice/action history |82 subjects screened;31 keyword candidates+10 additional semantic commits fully read in owned-file patches. |
| Publication/store history |114 current-name keyword SHAs+67 nonoverlapping literal predecessor SHAs fully read. Current and predecessor ledgers retain classification and ancestry/context. |
| Executor history |107 current-name+26 predecessor keyword SHAs fully read;133 total,44 historical repair classifications including metrics. |
| Queue-base/immediate history |All67 commits' owned-file patches read;19 keyword hits;18 significant correction candidates, not18 confirmed bugs. |
| Deduplicated history |**364 unique SHAs reviewed**, comprising314 keyword-union SHAs and50 additional semantic/context SHAs. This is not364 distinct bugs: duplicate/cherry-pick/refactor/metrics matches are individually classified. See `evidence/history-coverage.json`. |
| Issues collected |**141 unique issues**, union of11 live keyword/label searches, each limit1000; no search reached that limit. Raw search counts/results under `evidence/upstream/`. |
| Issues deeply read |**30 full issues /81 comments**, disjoint parallel batches10 each; every referenced issue's full body/comments read. |
| Issue dispositions |**8 historical/reproduction-backed confirmed reports,4 acknowledged design limitations,8 false-causal/user-error exclusions,10 uncertain**. These are discussion classifications, not current defect counts. Full per-issue ledgers retained. |
| Open PR census |**387 open PRs** collected with title/body/files/head; all title/file entries screened,49 broad core-path overlaps. A broad keyword detector matched236 including boilerplate; this is explicitly not a bug-fix count. Semantic title sweep also found relevant interface proposals outside core paths. |
| PR discussions deeply read |**62 unique full PR discussions**, including32 still open at the snapshot; review bodies and inline comments included. Subsystem ledgers distinguish complete diff review from full-thread/changed-file scope screening. |
| New adverse findings |**1 source-discovered queue-progress defect**, CR-1; native controlled reproduction with independent SQLite persistence evidence. No new publication or executor defect established. |

History queries OR-ed `fix, bug, race, panic, deadlock, correctness, crash, corrupt, leak, inconsistent, wrong` (publication/checkpoint also safety), used full local history rather than a shallow sample, and included old literal paths. Every significant candidate was classified; already-fixed mechanisms remain reference context. Detailed ledgers, raw diffs, raw threads and complete read/audit records are part of this deliverable's evidence trail. Enumeration/screening is not called deep issue reading.

### Important cross-review corrections

- Issue11188 remains OPEN, but its statistics-map race is fixed by c23064d/PR11253 at the pin. Issue state alone is not current-bug status.
- Issue9599 was initially uncertain from the issue alone; the parent read PR9619's complete thread, where a maintainer explicitly links the fix, and verified queue_factory_base.go219-243. Final classification is confirmed historical/fixed.
- Issue10320's Matching deadlock diagnosis is explicitly disputed;10321's SQL transaction-sharing account is unconfirmed;9563 and3131 were corrected to user/workload/environment problems. Their titles are not accepted as queue failure evidence.
- Open PR12016 is a scheduled time-boundary cleanup characterization. Open PR12014 is Cassandra QueueStore/QueueV2 delayed publication below retired message boundaries. Neither is the new History immediate Transfer reader-cursor defect; neither's backend/scope is silently imported into the SQLite model.
- PR11403 already proposes a bounded Worker Deployment activity timeout for the scenario in issue11402; its test does not establish durable DLQ readback before fault release. Keep that known discussion separate from this audit's independent SQL DLQ evidence.
- SQLite's connPool intentionally retains physical connections after manager/factory Close (`sqlite/conn_pool.go:63-84`). Earlier exploratory logs claiming physical close/reopen are superseded. Final tests distinguish **manager reconstruction**, **independent SQL connection readback**, and **post-Go-process independent snapshot readback**; no whole-service crash or power-loss test is claimed.

## Backend, configuration and structural map

Selected backend is Temporal's real SQL implementation with the SQLite plugin (`modernc.org/sqlite v1.51.0`, Go1.27.0). Focused publication and checkpoint stores use file-backed WAL with synchronous FULL and ordinary isolation. Publication uses4 connections and RangeSizeBits3 to expose boundaries compactly; checkpoint uses the plugin's default single connection. Production RangeSizeBits is20. The SQL transaction, conditional-version/range checks, read/delete predicates and plugin isolation are detailed in Appendix B. Cassandra/PostgreSQL/MySQL are not validated substitutes for this backend.

The ordinary functional control uses testcore's shared four-shard SQLite cluster; the tested workflow belongs to one shard. The model covers one shard. Testcore storage and service/worker behavior are actual implementations, while unit/store probes replace selected admission/execution seams with controlled callbacks. No test-case denominator is implementation coverage.

| Configuration at pinned default | Value / source |
|---|---|
| Transfer batch / maximum readers |100 /2; dynamicconfig/constants.go2263-2267,2323-2326 |
| Transfer reader poll / checkpoint |1minute /30seconds, each jitter0.15;2293-2311 |
| Pending critical / maximum / slices critical |9000 /10000 /50;2054-2086 |
| Move-group base / multiplier |500 /3;2104-2114 |
| Predicate size / shrink pending group limit |10KiB /10;2088-2103 |
| Shard I/O concurrency / timeout |1 /5seconds;2018-2026 |
| Shard metadata batching |5minutes, first interval10seconds,1000 completed tasks across queues;2674-2690 |
| History DLQ enabled / unexpected error budget |true /70; Internal-immediate-DLQ false; regex empty;2949-2971 |

Cursor probe keeps batch100/readers2/move500/predicate10KiB and directly schedules checkpoint calls; it forces ShardUpdateMinInterval0 so durable state is immediately observable. The lag-control probe uses a one-hour interval after priming an initial durable state. These are timing/observation overrides, not a claim every production setting was exercised.

| Component / concurrency | Critical atomic or split boundary |
|---|---|
| Workflow transaction + persistence | History nodes append first; accepted mutable-state mutation, task rows and conditions share a later SQL transaction. Commit and receipt may differ. |
| Shard task allocator/tracker | Under shard lock, assign IDs/register request minima. Uncertain result keeps pending minimum after local RPC inflight count drops. |
| Ownership | RangeID conditional SQL transaction fences stale workflow/task/checkpoint writes. In-place reacquisition retains memory; new Context loads durable state. |
| Queue event loop | Poll/new-range, checkpoint and mitigation serialize; no durable mid-move snapshot. Reader goroutines and executor ACKs interleave. |
| Reader / slices | Reader mutex guards ordered lists, iterator positions and tracker maps. Executable completion has a separate lock. Durable scope coverage is distinct from nextReadSlice accessibility. |
| Concrete executor / Matching | Eligibility validates run/task/stamp/state before RPC; downstream commit/start and response are distinct. Old comparable task clocks may be valid duplicates. |
| Checkpoint / deletion | Compute minimum retained scope; DELETE first; update local deletion frontier after observed success; SetQueueState may update memory only; later whole-shard snapshot is separately fenced. |
| DLQ | Independent SQL enqueue commit; no History RangeID fence. Lost receipt retains original Pending; retries can create duplicate durable DLQ messages. |

Reference comparison: pinned architecture documentation describes a transactional outbox rather than a supplied consensus paper. Implementation-specific extensions are multiple predicate-bearing readers, private allocation epochs, pending-write minima, separate memory/durable checkpoints and local cursors. Upstream PR11570 reports TLA+ use for another Matching reader; generic use of formal modeling here is not a novelty claim.

## Findings, reachability and compensation

### CR-1: checkpoint removes the slice referenced by nextReadSlice

**Source**: reader.go350-369,438-505; slice.go307-418; iterator.go47-62; queue_base.go295-361. `ShrinkSlices` removes an empty list element without resetting the read cursor. Every other relevant list transformation resets it. A full batch leaves an exhausted iterator in the slice until the next load; all its tasks can ACK first, so a checkpoint removes that slice. The subsequent reader turn follows the removed element's disconnected Next pointer to nil, abandoning later retained slices.

**Native state construction**: persist500 WorkflowTask rows plus Activity502; default scopes[1,501),[501,503). Load501 pending wrappers; real checkpoint/move-group sees501>=500 and moves that namespace to reader1. ACK prefix1..400, checkpoint and reconstruct from persisted metadata; resulting reader1 scopes are[401,501),[502,503). This establishes the structural precondition through actual queue actions. The task rows are test fixtures; no claim is made that one real workflow generates501 simultaneously required dispatch tasks.

**Fault schedule and control**: ACK the full batch401..500, then checkpoint before the next reader turn. Only100 submissions occur and the cursor becomes nil; Activity502 survives. Three normal default polls/checkpoints/Notify cycles do not repair reader1. With the next read before checkpoint, the healthy control submits101 including502. Reconstruction from the actual durable scope also submits502; after its controlled ACK, actual range deletion empties the table.

**Persistence endpoints**: independent database/sql read verifies physical502; final standalone `evidence/cursor-stalled.sqlite` contains row502 and its shard checkpoint. After the Go test process exits, a separate Python process verifies that snapshot and integrity. `evidence/cursor-stalled-independent-readback.json` records physical identity, durable metadata and hash. Model/queue reconstruction reads the serialized scope, not a fabricated success flag.

**Compensation**: default reader periodically gets Append/Merge resets; nondefault does not. Conditional move/clear/compaction or reload can repair. Immediate queues cannot trigger the scheduled-reader-stuck monitor. The remaining nonempty scope prevents empty-reader removal and prefix deletion past502. Thus the demonstrated consequence is indefinitely unread live work under stable ownership and no new list mutation, with durable recovery preserved.

**Evidence**: `reader-cursor-test.log` (minimal native batch1); `checkpoint-sqlite-final-tests.log` (production batch100 and native movement); `checkpoint-sqlite-cursor-native-prep.log`; saved test sources/patches and standalone readback. The primary test uses controlled scheduler ACK and no workflow mutable-state rows; a full-engine adversarial Workflow/Activity reproduction remains TV-1. Severity recommendation is a **High-priority progress defect** under the reproduced queue precondition, with end-user severity/frequency pending that endpoint test. Do not call it data loss.

**Novelty boundary**: reviewed all current reader history and relevant discussions, plus live searches for ShrinkSlices/nextReadSlice/reader-stall/slice-checkpoint/queue-cursor. No matching existing discussion was found. This is not a guarantee of global novelty. It differs from fixed AppendSlices and map-race issues.

### CR-2: duplicate-key tracker merge can overstate per-group counts

`tracker.go:58-83` overwrites a key in pendingExecutables while incrementing pendingPerKey. Optional predicate widening and overlapping scopes after reconstruction can introduce duplicate executable keys across readers. Merging can leave inflated group statistics after a single retained wrapper ACKs; broad predicate retention or mitigation decisions may follow. Exact live/default-threshold reachability and a user consequence are not reproduced. Monitor totals use actual executable-map length and empty ranges are still removed, so no row-loss or permanent-stranding conclusion follows. Preserve as a test-verifiable/code-review observation; do not impose exact-once delivery.

### CR-3: semaphore failure can leave checkpoint batching bookkeeping advanced

`shard/context_impl.go:1252-1295` resets last-update time/completion counters before semaphore acquisition; acquisition failure returns before store-error restoration. Memory QueueState is retained, and later time/task thresholds can permit retry. Source review supports possible delayed checkpoint publication, not permanent loss under finite contention and stable ownership. Retain for local fault/latency audit; it is not a standalone expensive MC hunt.

### Established contracts and known limitations

- Unknown publication: native ExecuteAndTimeout commits row9 but pending minimum holds watermark9; range renewal fences delayed old task10 before exposing16. No current publication-skip defect established.
- Checkpoint lag: successful prefix DELETE plus lagging durable metadata is intentional. Lost DELETE reply leaves local/durable checkpoint behind and retry is idempotent; unfinished row2 survives every tested schedule.
- Old ownership: actual SQL rejects stale writer/checkpoint, while unfenced old prefix DELETE preserves successor16 because immediate task-ID epochs do not overlap. This relies on a correctly authorized completed prefix and no integer wrap; it is not a statement about scheduled time-only cleanup.
- Matching acceptance: normal spool waits for durable CreateTasks; sync match waits for History start. Intentional Internal/DataLoss/stale terminal drops can also make Add return nil. The model must expose that exception and establish actual error producers before claiming a transient-error loss.
- DLQ: native lost enqueue reply leaves original Pending with one durable row; retry ACKs after another durable insertion, giving two copies. Original task42/source shard1/message IDs are independently decoded from SQL. Operator replay, rather than automatic History retry, supplies later business progress after durable DLQ acceptance.
- Postacceptance build-ID metadata writes intentionally mask errors; accepted dispatch and start-time identity updates compensate. Speculative/worker-deployment machinery is outside the ordinary baseline.

## Priority-question disposition

| Question | Checked paths and evidence | Result | Remaining verification |
|---|---|---|---|
| Q1 publication/high watermark | Full workflow→shard→SQL path;12 allocator tests,43 shard tests,33 real-store regressions; executed-after-timeout row readback and stale writer fence | No adverse publication outcome shown; uncertain minimum/epoch and periodic notification compensation verified narrowly | Actual workflow mutation+lost reply through full Context reacquisition and queue dispatch; composed MC with checkpoint |
| Q2 readers/slices/retry | Full reader/slice/scope/actions; all queue tests; movement-derived CR-1, durable state and row readback | CR-1 live cursor stall confirmed; durable scope gap not shown | Full-engine eligibility/outcome; combinations of clear, overlap, retry, movement, crash |
| Q3 delete/state separation | Healthy, actual ExecuteAndTimeout DELETE, batched-state-lag controls; native reconstruction and retained row2 | Tested lag/lost-delete receipt safe; no permanently uncleanable row shown | Both precommit failure and committed-lost reply at UpdateShard, same-epoch snapshot reorder and ownership composition |
| Q4 old owner | Protected SQL writes rejected; late prefix deletion preserves successor ID; complete executor/callback contracts | Store fencing/range separation verified; late RPC effects require identity/idempotency contract | Full old/new History-service concurrent executor schedule and callback outcomes |
| Q5 downstream/ACK/progress |113 distinct executor-related test leaves; real Workflow/Activity healthy control;3 real SQL DLQ fault controls;12 intentional Matching drop tests; CR-1 normal-cycle nonprogress | ACK is not workflow completion; durable DLQ needs replay; source/native CR-1 disproves unconditional live-reader progress | Full combined fault/worker endpoint, justified terminal-error producers and liveness model under explicit assumptions |

## Validation ledger and limits

| Check | Observed result | What it establishes |
|---|---|---|
| Existing queues package, before added probes |PASS (`queues-all-tests.log`) | Existing regression baseline; no novel schedule assumed covered |
| Final entire queues package |PASS5.213s (`queues-all-final-tests.log`) | Existing tests plus current shared investigation probes; package pass is not a formal verdict |
| Cursor/checkpoint focused tests |5 leaf cases PASS1.587s (`checkpoint-sqlite-final-tests.log`) | Native movement/full-batch stall, healthy control, lost DELETE reply and lagging checkpoint |
| Race-enabled cursor/checkpoint tests |PASS4.023s on native-preparation version before later observation-only copy/readback changes | No race detected in that controlled execution; not exhaustive concurrency proof |
| Publication tests |89 distinct leaves PASS |12 allocator/tracker+43 Context+33 SQLite-file persistence+1 focused SQL outcome/fencing test; no aggregate model coverage |
| Executor/interface tests |113 distinct leaves PASS |80 queue executable/rescheduler/DLQ+9 Transfer executor+8 start-handler+1 real functional+12 Matching terminal-drop+3 new durable DLQ; overlap with whole queue package is not added again |
| Independent publication readback |Only successor16,RangeID2,integrity ok after Go process exit | Actual retained file rows/fencing/deletion result |
| Independent cursor snapshot readback |Only task502,RangeID1,integrity ok after Go process exit | Persisted stalled-state artifact independent of original manager |
| Independent DLQ SQL readback |Message rows1/1/2 for healthy/prewrite-retry/lost-reply-retry, decoded task42/source shard1 | Actual durable acceptance and duplicate records; no service restart/operator replay |
| Native lint, unfiltered queue+shard packages |154 baseline issues; no diagnostic in investigation files | Whole-package lint **does not pass**; filtered fast-lint zero would omit untracked tests |
| Final unfiltered queues lint |112 baseline issues; none in three added queue probes | Latest observation additions checked; `checkpoint-final-unfiltered-lint.log` |
| Errortype vet |PASS, exit0 | Explicit queue+shard vet run after lint stopped on baseline issues |

Exact commands are stored in executor `*.command` files and the subsystem audit appendices; raw stdout/test JSON and exit codes remain in evidence. Commands always use `-tags test_dep`. Early failed mock setup, initial overly broad selectors, linter-process collision and initial pool-reuse wording are retained as exploratory evidence and superseded by named final results. No failed/unfinished attempt is counted as a successful verification.

Representative replay commands from the pinned repository:

```sh
go test -tags test_dep ./service/history/queues -run '^TestAnalysisReaderCheckpointCursor$' -count=1 -v -timeout=2m
TEMPORAL_HISTORY_QUEUE_EVIDENCE_DIR=<output>/evidence go test -tags test_dep -count=1 -run 'TestQueueBaseSuite/TestCheckpointSQLite' -v ./service/history/queues
TEMPORAL_PUBLICATION_EVIDENCE_DIR=<output>/evidence go test -tags test_dep ./service/history/shard -run '^TestPublicationPersistenceEvidence$' -count=1 -v
go test -tags test_dep ./tests -run '^TestActivityTestSuite$/^TestActivityHeartBeatWorkflow_Success$' -count=1 -timeout=10m -json -persistenceType=sql -persistenceDriver=sqlite
```

`<output>` denotes this report's directory. The four added diagnostic test files are preserved in the source checkout and copied under evidence/test-sources; no production implementation was changed, staged, committed or published. Snapshot copying occurs after SQLite WAL checkpoint and is for retained evidence, not a claim of a crash-consistent whole-Temporal backup.

## Formal handoff: contribution and assumptions

Formal exploration has not yet contributed a discovery. Source review plus targeted native tests found CR-1; current tests also support the intended publication, ownership, deletion and DLQ contracts. Useful added formal evidence would be a new reachable failure interaction, a distinct consequence, or bounded compositional assurance under implementation-faithful contracts. Merely recovering CR-1 or a closed historical fix must be labeled reconfirmation/reference, not MC-first discovery.

The brief therefore preserves structural cursor/list identity, pending-write minima, actual transaction units, separate store outcome/receipt, memory/durable snapshot distinction, wrapper cancellation and explicit downstream responsibility. A model allowing arbitrary selection from every retained scope would silently repair CR-1. A fairness assumption allowing unsolicited healthy reload would similarly mask its progress failure.

Required future observations: persistence operation request/commit/outcome and independent readback; actual ordered reader lists/cursor, iterator range and executable state; eligibility/executor/start/discard/DLQ result; durable serialized QueueState; reconstruction endpoints. Negative controls must reject an omitted pending row, false durable checkpoint, incorrect predicate/cursor or fabricated ACK. The current command logs are not complete model-state traces.

Progress requires eventually stable ownership, positive scheduler/reader capacity, eventual store/RPC responses and finite transient failures, plus fair service or a finite eligible workload. Worker execution needs a live worker. Operator replay is an additional assumption for DLQ business completion. Terminal corruption/discard cannot be silently recast as successful workflow delivery. Numeric bounds and narrower checks must be explicit; a completed small model will not certify an uncompleted larger cross-product.

## Complete audit appendices and evidence index

- [Reader/slice/action audit](evidence/reader-slice-audit.md), [reader history ledger](evidence/reader-history-ledger.md): complete source paths, CR-1/CR-2, all local exclusions and full-batch reasoning.
- [Publication/persistence audit](evidence/publication-persistence.md), current/predecessor history and issue/PR ledgers: atomic mutation, unknown result, range allocation/reacquisition, SQL fencing, CR-3, native store proof and remaining API gap.
- [Checkpoint/recovery audit](evidence/checkpoint-recovery.md), history/issue ledger: native movement preparation, real store outcomes, durable scope reconstruction, deleted/retained row distinctions and corrected pool lifetime.
- [Executor/interface audit](evidence/executor-contract.md), executor history/issue/open-PR ledgers: complete HandleErr matrix, actual Matching contract and exceptions, DLQ acceptance and all executed commands.
- [All-open-PR screen](evidence/open-pr-scope-ledger.md); `discussion-coverage.json`, `history-coverage.json`, `upstream/issue-search-counts.json`, complete raw issue/PR collections and per-commit patches.
- Primary standalone evidence: `cursor-stalled.sqlite`, `cursor-stalled-independent-readback.json`, `publication-independent-readback.json`; publication DB path/hash in its readback file; `executor-dlq-durable.jsonl` and independent decoded payload assertions.

The linked appendices are integral detailed audit trails, not substitutes for the findings and verdict above. They retain lower-level observations and exclusions even where no TLA+ target is recommended. The next phase should start from modeling-brief.md and preserve these evidence categories.
