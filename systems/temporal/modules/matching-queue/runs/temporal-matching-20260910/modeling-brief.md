# Modeling Brief: temporal-matching

## 1. System Overview

- **System/revision**: Temporal Matching, Go; `temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, verified clean checkout; ~5,400 LOC in nine matching core files, plus task stores.
- **Category A (Distributed / Message-Passing)**: conditional disk transactions, History RPCs, goroutines and owner replacement compose across crashes; local locks are atomic regions, not a Category B/BFT model.
- **Algorithm**: durable task queue delivery; no single supplied reference paper/spec. Separate sync acceptance, durable records, read/bypass, completion, metadata, GC and lease generations.
- **Initial configuration**: one normal unversioned physical partition, fixed normalized priority 3; `matching.useNewMatcher=true`, `matching.enableFairness=false` are defaults (`common/dynamicconfig/constants.go:1600-1616`; `service/matching/config.go:403-409`).
- **Backend**: initial SQL TaskStore **V1**; real file-backed SQLite suites executed. PostgreSQL/MySQL/Cassandra source-audited only; V2 belongs to fairness (`common/persistence/sql/task_store.go:38-47`).
- **Concurrency**: one writer per owner; one reader per subqueue; reader/matcher/DB mutexes; independent History calls, read results, metadata sync, GC and unload (`pri_task_writer.go:152-179`; `pri_task_reader.go:35-60,522-577`; `db.go:700-765`).
- **Evidence status**: 19 priority unit children passed/10 skipped; 14 SQLite file-store children passed. No new bug confirmed; no implementation NDJSON traces, trace validation or TLC baseline executed in this Code Analysis phase.

## 2. Scenarios

### Scenario 1: Acceptance, uncertain persistence, and fresh ownership

**Mechanism**: a durable transaction, local completion/notification and caller receipt occur separately, while a new owner reconstructs obligations from older metadata.
**Evidence**:
- Historical: `b63e93f4` (#10018) restored idle ownership detection; `9307d48c` (#11046) distinguished definite rate-limit rejection; `4da89bcd` (#9739) reduced metadata-on-append writes. These are fixed reference context.
- Code analysis: submitted append can commit before shutdown wins receipt selection (`pri_task_writer.go:68-98`); only successful writes signal readers (`124-137`); maxRead advances on errors (`db.go:575-596`).
- Takeover reads metadata, conditionally increments range and sets maxRead to the previous allocation-block end (`db.go:176-207,241-258`); an intervening old-owner metadata update can be overwritten by the takeover snapshot, allowing safe durable-ack regression/replay.
**Affected code paths**: AddTask, TrySyncMatch/Offer, SpoolTask/appendTasks, CreateTasks/writeDefinitelyFailed, RenewLease/SyncState, unloadTaskQueuePartitionByKey.
**Suggested modeling approach**:
- Variables: `records`, `logicalWork`, `observedAdd`, `storeOutcome`, `pendingAppend`, `ownerRange`, `persistedMetadata`, `cachedMetadata`, `notifyPending`.
- Actions: separate transaction commit/rejection, returned error/lost response, notification, caller retry, Stop and fresh reacquisition. Keep SQL transaction/Cassandra conditional batch atomic.
- Granularity: serialize writer and DB-lock operations per owner; permit different owners and unfenced read/GC I/O to overlap. Queue-shutdown error is not direct-store proof of noncommit.
**Priority**: High.
**Rationale**: Q1/Q4; wrong certainty or restart boundaries can invalidate every conservation claim. A parked priority reader has no periodic scan; uncertain admission needs a justified retry/wakeup/reload path.

### Scenario 2: Read snapshots, bypass, and proof of an empty interval

**Mechanism**: delayed read results describe captured bounds while bypass and completion mutate the current outstanding/ack frontier.
**Evidence**:
- Historical: `83b35dc3` (#11570) fixed stale read/ack interactions and cites private TLA+ work; `3fd45b56` (#9841) fixed disabled bypass; `2a10a6d1` (#11047) propagated gap ack to cached metadata. Do not recreate pre-fix guards.
- Code analysis: read captures bounds before I/O (`pri_task_reader.go:214-244`); processing filters expired/<=ack/outstanding duplicates (`247-282`); bypass requires prior-max equality and capacity (`382-411`); stale gaps are rejected (`484-511`).
- New backend-conditional question: empty `Tasks` advances to the full upper bound although `NextPageToken` is ignored (`224-244`; `db.go:700-715`); Cassandra returns explicit continuation (`common/persistence/cassandra/matching_task_store_v1.go:154,187-188`). Empty nonterminal page production is unverified on a prospective Apache Cassandra release/configuration.
**Affected code paths**: getTaskBatch/processTaskBatch, signalNewTasks, setReadLevelAfterGap, recordNewTasksLocked/ackTaskLocked, GetTasks.
**Suggested modeling approach**:
- Variables: `readRequestBounds`, `readResult`, `readLevel`, `maxReadLevel`, `outstanding[id]`, `loaded`, optional backend `pageContinuation`.
- Actions: issue/read-return/process, bypass-register/add-to-matcher, out-of-order finish, empty-gap processing; do not infer an empty interval from a model-generated cursor.
- Granularity: reader-lock mutations are atomic; I/O and matcher insertion are separate. Enable nonterminal-empty-page behavior only for a justified, separately recorded backend configuration.
**Priority**: High.
**Rationale**: Q2 and adjacent backend contract; gaps and duplicates are legitimate, but skipping a later eligible record is not. Existing fake tests cannot establish paging behavior.

### Scenario 3: Completion prefix, delayed metadata, and old-owner cleanup

**Mechanism**: completed record prefixes authorize deletion independently of durable metadata, including across outstanding old-owner operations.
**Evidence**:
- Historical: `62f3d931` (#7469) fixed ack/stat and GC snapshot races; `e160dc04` (#8007) synchronized final reader ack on stop. Fixed reference context only.
- Code analysis: ack removes a completed minimum prefix and may jump when drained (`pri_task_reader.go:452-479`); GC captures ack and deletes below ack+1 independently of SyncState (`522-577`; `db.go:298-333,741-765`).
- Stop refreshes cached reader ack before cancellation, while ownership conflict skips final metadata (`pri_backlog_manager.go:108-144`; `physical_task_queue_manager.go:319-344`).
**Affected code paths**: completeTask/ackTaskLocked, updateAckLevelAndBacklogStats, maybeGC/doGCAt, SyncState, RenewLease, Stop/unload/reload.
**Suggested modeling approach**:
- Variables: per-owner `ack`, durable `ack`, `gcRequestBound`, outstanding completion flags, durable records and replacement lineage.
- Actions: finish/ack, metadata transaction, start/finish GC, steal lease, late old-owner callback, reload.
- Granularity: GC uses its captured bound; no invented range CAS on task deletion. Persisted ack may lag or regress across takeover; memory ack is monotone only within an owner.
**Priority**: High.
**Rationale**: Q3/Q4; prove semantic safety of deleted work rather than an incorrect `GC <= durableAck` invariant. All-expired cleanup is a separate known test gap.

### Scenario 4: History outcomes and replacement before original acknowledgement

**Mechanism**: dispatch outcomes can discharge work, retry the same record, or transfer its obligation to a new record; Worker receipt is later than queue completion.
**Evidence**:
- Historical: [#4612](https://github.com/temporalio/temporal/issues/4612) documents dispatch-failure rewrite pressure; [#11733](https://github.com/temporalio/temporal/issues/11733) is an unconfirmed current lost-start-response report, not a new finding established here.
- Code analysis: transient errors re-add; other errors re-spool; replacement failure returns without original ack (`pri_task_reader.go:114-156`), sets skipFinalUpdate and unloads (`pri_backlog_manager.go:360-387`).
- Matching finishes before poll response return (`matching_engine.go:885-887,1128-1130`). History idempotence uses RequestId, while each outer attempt generates a fresh one (`3511-3527,3590-3606`; `service/history/api/recordworkflowtaskstarted/api.go:98-111`; `recordactivitytaskstarted/api.go:150-183`).
**Affected code paths**: PollWorkflow/ActivityTaskQueue, RecordTaskStarted, task.finish, completeTask, respoolTaskAfterError, addTaskToMatcher/retryAddAfterError.
**Suggested modeling approach**:
- Variables: `historyAccepted`, current eligibility/stamp, start RequestId, `workerReceipt`, completion reason, `replacementOf`, pending replacement write.
- Actions: match, History effect, History reply/loss, Worker return/loss, transient retry, replacement commit/failure, ack and supported unload.
- Granularity: retain start-result classification and logical identity; sync pair alone is not acceptance, and TaskAlreadyStarted does not prove Worker receipt. Speculative History durability/recovery stays an explicit external contract.
**Priority**: High.
**Rationale**: Q1/Q5; this distinguishes queue safety from stronger end-to-end Worker delivery. Fatal Internal/DataLoss drop classification needs code review rather than assumed obsolescence.

### Scenario 5: Fairness eviction during unlocked replacement (separate extension)

**Mechanism**: a completion verifies membership, releases the reader lock for replacement I/O, then acknowledges after concurrent merge has evicted that record and lowered the read boundary.
**Evidence**:
- Historical: `ad717eae` (#8093) fixed eviction-before-matcher-add; later fairness merge/ack fixes document sensitivity. Retain those fixes; this candidate concerns a different current unlocked callback window.
- Code analysis: membership check/unlock/re-spool/relock without recheck (`fair_task_reader.go:153-218`); merge evicts matched records and retracts read (`514-551`); leading ack processing can then cross absent entries (`608-637`).
- Source schedule: initialized empty queue atEnd=true, batch=3/reloadAt=0; same-key A(1000,1),B(2000,2),C(3000,3) all matched; pause C's failed-start callback before replacement enqueue; fresh-key Y(1000,4),Z(1000,5) evict B,C; commit C replacement R(4000,6); resume C completion; finish A,Y,Z before read processing. B also receives a namespace RPS rejection, never starts; ack may cross B. Full schedule/compensations: analysis-report.md, separate fairness extension.
**Affected code paths**: fair completeTask/completeTaskLocked, mergeTasksLocked, advanceAckLevelLocked, fair writer writeBatch/pickPasses, respoolTaskAfterError.
**Suggested modeling approach**:
- Variables: `(pass,id)` levels, live outstanding entries versus ack markers, read/end state, ack pin, newly-written merge queue, evicted acks and pending replacement callback.
- Actions: split completion around re-spool I/O; allow valid write-merge trimming while callback is unlocked; preserve single-writer ordering and write ack pin (`fair_task_writer.go:214-230`).
- Granularity: exact map counter is sufficient at small key count; separate SQL/Cassandra V2 persistence. No weighted/global fairness property is required.
**Priority**: High once priority baseline is calibrated; extension gated until then.
**Rationale**: a concrete unaudited current-source safety candidate, not an executed reproduction. Initial V1 priority results do not validate this extension.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Logical work versus storage/start identities | S1/S4: retry and replacement create duplicates | Map queue/subqueue/TaskId records to namespace/workflow/run/type/scheduled-event/stamp; separate RequestId |
| Atomic store outcome and independent receipt | S1: timeout need not mean rejection | Commit/reject transaction atomically; choose observed outcome independently where backend permits |
| Captured reads, bypass and outstanding prefix | S2/S3: stale results and out-of-order completion | Distinct request/result/current cursors; exact outstanding sets, not backlog gauges |
| Cached/durable metadata, lease and GC | S1/S3: replay and old-owner I/O | Keep all boundaries separate; replace owner through real unload/reacquisition |
| History contract and replacement recovery | S4: proper task disposal/progress | Guard expiry/obsolete/started results, separate Worker receipt; preserve replacement-before-ack |
| Fairness merge/eviction extension | S5: late callback after trimming | Enable only after complete priority traces and bounded baseline; retain current pin/dedup mechanisms |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| History internal outbox, workflow execution, replication | Explicit boundary; expose acceptance/eligibility/recovery contracts only |
| Migration, dynamic partitions/forwarding, worker-version routing | Explicit exclusions; capture and settle fresh empty V2 drain setup rather than fabricate a disable flag (`db.go:217-218`) |
| Strict global order, cross-priority or weighted fairness | Outside fixed-priority durable-delivery contract |
| Exact approximate-backlog statistics, telemetry, Go allocation details | Not task conservation; use tests/review for local issues |
| Reverted historical guards, globally monotone durable ack, GC fenced by range | Would change the implementation or retarget already-fixed bugs |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Acceptance and uncertainty | `observedAdd`, `storeOutcome`, `pendingAppend`, `notifyPending` | Separate effects from receipt/wakeup | 1 |
| Durable ownership and metadata | `ownerRange`, `cachedAck`, `durableAck`, pending metadata | Model takeover snapshots, conditional writes and replay | 1,3 |
| Reader/bypass concurrency | captured bounds/result, `read`, `maxRead`, `outstanding`, `loaded` | Preserve read proofs and completion prefix | 2 |
| Independent cleanup | captured `gcBound`, durable rows | Check deletion across delayed metadata/owners | 3 |
| History and record replacement | `historyAccepted`, `workerReceipt`, `eligibility`, `replacementOf` | Discharge/transfer logical obligations | 4 |
| Backend paging (conditional) | `pageContinuation`, returned rows | Separate page emptiness from interval exhaustion | 2 |
| Fairness callback/merge (gated) | levels, ack markers, pin, evicted acks, pending replacement | Check eviction during unlocked completion | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TypeOK / RecordIdentity | Safety | All state well typed; identities and replacement lineage preserve logical work | All |
| AcceptedWorkCovered | Safety | Each successfully acknowledged still-eligible work has accepted History start or recoverable durable record/replacement, including lost acknowledgement replies; track committed-error initial admissions separately | S1-S4 |
| AckPrefixSound | Safety | Advancing ack cannot skip the sole eligible undispatched record of logical work | S2/S3, MC-4/5 |
| DeletionSound | Safety | Deleted eligible work is already discharged or carried by a valid replacement; no durable-ack inequality assumed | S3/MC-2 |
| RangeConditionalWrite | Safety | A committed fenced write matched the durable range at its atomic commit; late GC/read not subject to invented fencing | S1/MC-1 |
| ReplacementBeforeRelease | Safety | Failed replacement does not release the original obligation; any substitute has matching logical identity | S4/MC-3 |
| PerOwnerCursorMonotonic | Safety | Priority read/ack do not regress within one owner; does not apply globally or to fair read trimming | S2/S3 |
| EventuallyDischarged | Liveness | After stable owner/available services, eligible polling, finite interference and eventual processing/retry, accepted eligible work reaches History acceptance or valid disposal | S1-S4 |
| FairAckWithinTrackedPrefix | Safety | A late callback cannot bridge evicted unresolved work or miscount loaded entries | S5/MC-5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if faulty | Scenario |
|---|---|---|---|
| MC-1 | Do uncertain writes, read/bypass overlap, retry and fresh ownership preserve each logical obligation? | AcceptedWorkCovered | 1,2 |
| MC-2 | Can late old-owner cleanup plus takeover/metadata interleaving erase still-required work or its replacement? | DeletionSound / AckPrefixSound | 3 |
| MC-3 | Does replacement commit/error/unload retain a delivery path after finite failures recover? | ReplacementBeforeRelease / EventuallyDischarged | 4 |
| MC-4 | If the selected backend permits empty nonterminal pages, can ignored continuation cause ack to skip live work? Backend capability must be verified first. | AckPrefixSound / AcceptedWorkCovered | 2 |
| MC-5 | Can fair re-spool completion after eviction ack across another evicted eligible task? Source schedule now reproduced in the separate controlled SQLite V2 diagnostic; formal fairness convergence and independent confirmation remain pending (CR-4). | FairAckWithinTrackedPrefix / AcceptedWorkCovered | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T-1 | Complete real-store trace and identity/queue-boundary observation gaps | Real V1 queue+store, independent commit/readback, all events through reload; corrupt copied identity/bound controls must fail validation |
| T-2 | Uncertain commit notification and supported recovery | Execute store write then return error; observe wakeup via retry/reload, replacement failure and old original retention |
| T-3 | Known all-expired priority cleanup gap | Enable/repair the currently skipped schedule with SQL retained expired rows; distinguish cleanup from eligible-work loss |
| T-4 | Backend paging reachability and fair callback schedule | Real selected Cassandra/compatible backend tombstones; separately real V2 trim/re-spool schedule after initial calibration |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Shutdown comment overstates noncommit (`pri_task_writer.go:94-95`) | Audit documentation and caller certainty interpretation; submitted write may already have committed |
| CR-2 | Internal/DataLoss/processing Internal drops do not intrinsically prove ineligibility | Follow actual error producers and recovery obligations before allowing these outcomes in conservation assumptions (`matching_engine.go:810-819,1037-1046`; `pri_task_reader.go:328-351`) |
| CR-3 | SQLite unbounded task-select branch dereferences absent upper bound (`common/persistence/sql/sqlplugin/sqlite/task_v1.go:62-68`) | Audit/test direct plugin callers; Matching V1 always supplies the upper bound (`common/persistence/sql/task_v1.go:124-131`), so keep outside queue MC |
| CR-4 | Previously listed S5/MC-5: late fair completion after eviction inserts an old ack, undercounts loaded tasks and crosses unstarted B. Reproduced with real SQLite V2 and a window-closed control; code-analysis origin, counted once. | Independent confirmation of [the controlled real-store diagnostic](spec/fairness-diagnostic.md), including full public API/reload scope; not a new MC discovery. |

## 7. Reference Pointers

- [Full audit and complete downstream trace/bounded-check handoff](analysis-report.md); [reader/ack evidence](analysis-evidence/reader-ack.md), [writer/store evidence](analysis-evidence/writer-store.md), [fairness/issues/open-PR evidence](analysis-evidence/history-fairness.md), [dispatch archaeology](analysis-evidence/dispatch-history/classification.md).
- Source root: `/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching`; unqualified Go anchors above are under `service/matching/` unless a different path is stated.
- Key backend anchors: SQL `task_v1.go:44-98`, `task_queues.go`; Cassandra `matching_task_store_v1.go:55-196`, queue metadata; DB `writeDefinitelyFailed:685-697`. Preserve transactions; V2 is extension only.
- Historical [#11570](https://github.com/temporalio/temporal/pull/11570) is private-model/fixed context; live open [#11879](https://github.com/temporalio/temporal/pull/11879) replaces fake tests with SQLite and is a useful harness reference, not code applied to this HEAD. Full discussion/status audits are archived.
- Paging contracts: [Cassandra native protocol](https://cassandra.apache.org/doc/latest/cassandra/reference/native-protocol.html#_7_result_paging); [Scylla empty tombstone pages](https://docs.scylladb.com/manual/stable/reference/configuration-parameters.html#query-tombstone-page-limit). Scylla behavior is not assumed for Apache Cassandra or SQLite.
- Proposed first bounded baseline: 1 queue/priority, 2 owners, 3 work items, up to 6 records, 2 pollers, small range crossing, 2 lease changes, 1 uncertainty/crash episode; 30 minutes/8 GiB per configuration initially. **Not executed**; retain exact bounds/states/depth/time and mark nonconvergence INCOMPLETE.
- Before any verification verdict: complete normal/overlap/failure+reload traces through real queue and store, observe History acceptance and Worker boundary separately, run negative observation controls, then exhaustive bounded safety and conditional liveness. No passing snippet or current unit result satisfies this requirement.
