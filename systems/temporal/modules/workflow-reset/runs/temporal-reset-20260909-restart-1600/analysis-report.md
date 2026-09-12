# Temporal Reset code analysis and execution audit

## Outcome and evidence status

**Two distinct Reset problems were reproduced locally through public APIs. Neither is a model-checking discovery or an upstream-confirmed new bug.**

1. **T-1 / CR-1 — exact Reset request replay creates another run and terminates the first.** Six file-backed SQLite cases cover ordinary same-current, distinct-current and supported missing-current states, each with a received or deliberately unavailable first successful response. The Reset ID never reaches the new execution's dedup field; original Start/callback identity occupies that field.
2. **T-2 / CR-2 — valid per-run Update IDs collide when Reset merges a Continue-As-New chain.** Two Updates sharing an ID complete successfully in different runs. Reset of the earlier run fails with Internal during reapplication. Ordinary and missing-current file-backed cases fail again on an identical retry; a separate in-memory SQLite shard-reload case does too. Different IDs and excluding Update reapplication succeed. This is Reset unavailability for these histories, not acknowledged data loss or permanent database corruption.

Positive evidence is equally material: **27 existing test cases passed**; a rejected missing-current Create recovered through shard reload and retry to workflow completion; a competing Start committed before a paused Reset Create, after which automatic retry produced a permitted Start-then-Reset order and the returned reset run completed; public deletion of a base preserved an acknowledged running reset's history and ability to finish. Exact artifacts and test semantics are below.

This is the requested **Code Analysis phase**, following the installed skill's classification, reconnaissance, archaeology, deep analysis and Scenario brief format. Formal modeling recommendations are delivered in [modeling-brief.md](modeling-brief.md). **TLC runs: 0; formal trace validations: 0; formal counterexamples/discoveries: 0.** The diagnostic execution logs have not been checked against a TraceSpec. Delayed persistence completion, process restart and several cleanup/completion interleavings remain explicit work for the responsible subsequent phases.

## Revision, configuration and preservation

| Item | Recorded value |
|---|---|
| Repository | `/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-reset` |
| Pinned/actual HEAD | `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` |
| Initial worktree | Clean; non-shallow Git history |
| Production implementation | Unmodified; three new diagnostic test files are the source overlay |
| Toolchain | Go 1.27.0; API module v1.63.5; SDK v1.48.0 |
| Build flags | `CGO_ENABLED=0`, `-tags test_dep`, `GOMAXPROCS=16`, build parallelism 8 |
| Shared functional backend | SQLite files, WAL, `synchronous=normal`, `cache=shared`, 30-second busy timeout; four history shards |
| Dedicated recovery backend | Real SQLite transactions in memory; one shard; `history.shardIOConcurrency=2`; transfer/visibility ack intervals one second |
| CAN shard-reload control | Dedicated SQLite memory; distinct from the ordinary/missing-current file-backed cases |
| Upstream snapshot | `ab596df51ba519e1159a1398def6b40c4cf4910c` retrieved during this investigation; Reset API and resetter blobs identical to pinned source |

Runtime file-backend configuration is preserved in the identity/history logs. Backend selection is grounded in `tests/testcore/functional_test_base.go:333-338,363-369`, `test_cluster_pool.go:361-379`, and `common/persistence/persistence-tests/setup.go:34-47,109-149`. `WithPersistenceFaultInjection` requests a dedicated cluster; its default SQLite is **not** the shared file backend. No process restart or power-loss durability is implied by `CloseShard` or WAL configuration.

All writes were local test/evidence artifacts. No GitHub issue, PR, comment or external application was written. Original frozen pipeline prompts and unrelated workspaces were preserved. The initial `/tmp` compilation quota failure was resolved using task-local build temporary directories under `/home/ubuntu`; shared data was not removed.

## Phase 1 — structural and concurrency map

**Category A (Distributed / Message-Passing).** Reset spans public Frontend → History RPC, leased mutable-state reconstruction, persistence and asynchronous queues. No Byzantine threat model or CPU memory-order model applies. Durable workflow execution supplies the reference contracts; a generic consensus invariant set would not describe this system.

Primary scale: Reset API 295 lines + resetter 1,414 = **1,709**. Adding transaction wrapper 849, SQL execution 762, Cassandra mutable state 1,155 and shard context 2,480 gives **6,955** lines. These are source-line counts, not implementation coverage percentages.

Completely read core files include those six files; `ndc/state_rebuilder.go`, `workflow/mutable_state_rebuilder.go`, `api/describemutablestate/api.go`; deletion manager/API and child-completion API; `common/persistence/history_manager.go`; public history and Signal APIs; history scavenger; and the three requested Reset/history-cleanup functional test files. Full-read lists and lengths are recorded in the [identity](evidence/identity/identity-audit.md), [persistence](evidence/persistence/persistence-audit.md) and [history](evidence/history/audit.md) audits. Larger neighboring frontend/mutable-state/callback/plugin files were read at complete relevant methods and caller/callee sites; this is not a claim that every Temporal file was read.

| Boundary | Source and checked behavior |
|---|---|
| Public validation/response | `service/frontend/workflow_handler.go:2418-2472`: validates Reset request/ID, forwards the same request, propagates failure and returns History's Run ID |
| Base lease | `service/history/api/resetworkflow/api.go:56-82`: loads base, retains lease until named return error is released, validates reset point |
| Current lookup | Same file `:86-121`; `workflow/cache/cache.go:463-493`: short empty-run/current lookup lock ends before Reset persistence; concrete current lease can be shared with base or separately acquired |
| Missing current | Reset API `:218-230`: only NotFound with explicit base Run ID is tolerated; other lookup errors propagate |
| Rebuild and work scheduling | `service/history/ndc/workflow_resetter.go:133-280,290-361,506-579`: set tentative link, fork/rebuild, reapply, post-reset operations, schedule workflow task, persist, then abort old Update registry |
| Cache release | Reset API `:71,121`; workflow cache `:386-389`: errors discard modified cached state; admin DescribeMutableState also forces a database reload by default (`api/describemutablestate/api.go:53-65`) |
| Response layers | History `handler.go:1130-1153,2291-2298`; `common/rpc/interceptor/retry.go:36-44`; History retryable client `:839-852`: one public call can contain multiple whole-handler attempts |

Workers, transfer/timer/visibility processors and ownership recovery run independently. The default per-shard I/O capacity is one (`common/dynamicconfig/constants.go:2018-2022`); it is held **per persistence call**, with a gap between the two missing-current writes. SQL can configure a larger capacity; Cassandra explicitly forces one (`shard/context_impl.go:2189-2196`). Base/current run leases constrain same-owner interleavings; they are not a transaction spanning all databases or the entire workflow ID lifetime.

## Phase 2 — archaeology coverage and interpretation

The complete case-insensitive keyword set was `fix|bug|race|panic|deadlock|correctness|crash|corrupt|leak|inconsistent|wrong`, applied to full commit messages and the explicitly listed source scopes, with pinned ancestry and `--all` checked. Every candidate's scoped changes were read and classified, including mechanically matched feature/refactor commits. There was no sampling of the resulting candidate sets.

| Scope | Candidate entries fully analyzed | Detailed ledger |
|---|---:|---|
| Reset API/resetter | 65 | [Core ledger](evidence/archaeology/core-ledger.md): 23 corrective, 29 mechanical, 13 feature/reference |
| Transaction/SQL/Cassandra execution | 26 | [Backend ledger](evidence/persistence/transaction-backends/commit-ledger.md): 10 historical fixes, 11 maintenance, 5 feature/reference |
| Shard context | 79 | [Shard ledger](evidence/persistence/shard/shard-ledger.md): all 238 changed hunks; 28 behavioral fixes, 6 observability fixes, 26 mechanical, 19 feature/configuration/performance |
| History/deletion/cleanup scope | 54 | [History ledger](evidence/history/commit-ledger.md); eight explicit paths in `commit-scope.json` |

The 224 scope entries contain **188 unique keyword-matched commits** because several touch multiple scopes. The independently traced identity change `ff2754a711cd0691741d6cc347675820e3c39b50` is an additional non-keyword discovery, making **189 distinct analyzed commits**. [Machine-readable denominator](evidence/archaeology/coverage-total.json). These are fixed-path historical queries, not all repository commits or a claim of complete pre-rename archaeology.

Issue/PR collection retained **520 unique numbered records** from search results, issue endpoints and the full open-PR inventory. **46 unique discussions were deeply read**, including all issue comments and, for PRs, review bodies and inline comments: identity 15, persistence 12, history 11, root open-PR follow-up 8. Counts describe records, not independent bugs. Deep classifications: **20 confirmed-bug records, 4 design-defect records, 11 uncertain records, 9 reference/feature records, 1 pending repair and 1 disputed/false record**. The disputed/false record is #4792's suggestion that deleting current should promote an earlier run; the maintainer says the observed behavior is intended. Scope exclusions are counted separately from false reports. [Collected/deep-read IDs and definition](evidence/archaeology/issue-coverage-total.json).

At the open-PR snapshot, **368** were open. Broad title/body keywords selected **197** possible corrective PRs; all 197 complete changed-file lists were retrieved without errors. **13** touched Reset or inspected dependency paths, and their full discussions were reviewed. Remaining entries are scope exclusions, not rejected correctness reports. [Complete open-PR scope ledger](evidence/archaeology/open-pr-ledger.md). Current relevant proposals include #11713/#11714 (SQL statement optimization preserving existing atomic conditions), #11774 (SignalWithStart with inverse orphan-pointer state), #10050 (CQL driver idempotency proposal) and #10671 (known Activity expiration problem). Their changes were not applied.

Historical mechanisms drive the five Scenarios, rather than a flat list of files: source/request identity conflation; non-atomic Reset metadata writes; stale current lookup plus conditional retry; cross-run reapplication identity; and branch-reference/deletion lifecycle. Closed fixes stay historical context. Neither recreating pre-#10926 behavior nor proving that the #6513 replication fix is useful is proposed as a new model-checking hunt.

Reference comparison uses the pinned API's request deduplication/Reset behavior, the SDK's per-run Update ID contract, reviewed Reset design discussions and the actual SQL/Cassandra implementations. There is no supplied formal reference algorithm with equivalent Reset/delete semantics. Current documentation's warning about repeating an administrative batch command does not establish that replaying a byte-identical request ID may create another run; these are separate operations. [Official recovery documentation](https://github.com/temporalio/documentation/blob/main/docs/production-deployment/worker-deployments/recover-pinned-workflows.mdx).

## Phase 3 — identity assignments and public outcomes

### T-1 / CR-1: Reset request identity does not reach persistence

The loaded API v1.63.5 marks Reset `RequestId` as used for deduplication (`workflowservice/v1/request_response.pb.go:4642-4643`). The tested scope is immediate replay while the first reset remains current, without another administrative operation, retention expiry or deletion between the two Reset requests.

| Identifier | End-to-end assignments and reads |
|---|---|
| Client Reset ID | Frontend forwards unchanged; Reset API `:124-135` compares it to current `ExecutionState.CreateRequestId`; it is absent from resetter arguments at `:180-203` |
| Candidate Run ID | Fresh UUID on each Invoke at Reset API `:136`; sent through reset construction and returned after successful persistence |
| Original Start ID | `workflow_resetter.go:230-247` calls `findStartRequestID`; `state_rebuilder.go:402-410` chooses Started entry in RequestIds or falls back to CreateRequestId |
| Rebuilt CreateRequestId | Selected Start ID passes prepare → replay → StateRebuilder → MutableStateRebuilder (`:152-175`) → ApplyStarted; `mutable_state_impl.go:2596-2612,3106-3123` writes map and CreateRequestId |
| Durable current/per-run state | `common/persistence/execution_manager.go:750-789,1213-1216` serializes/deserializes that same state; SQL execution `:179-196,402-410,506-518` copies it into current identity. Backend conditions do not synthesize the missing Reset ID |
| Callback identity | Same Start ID reaches HSM/CHASM callback construction and scheduler completion matching; detailed downstream anchors in the identity audit |

Merged [#9479](https://github.com/temporalio/temporal/pull/9479), commit `ff2754a...`, removed Reset's request-ID parameter to preserve scheduler callback identity. Full discussions and source were checked: preserving callback source identity is intentional, but no discussion establishes a corresponding change to the public Reset dedup contract. The assignment is unconditional; the reproductions attach no callbacks. Blindly reverting that callback fix is not an acceptable inferred repair.

Final identity tests use the public frontend, clone the exact request, inspect database mutable state and public histories, and then preserve the expected same-Run-ID contract assertion. All six finish with that equality failure. Both runs store the original Start ID; the Reset ID is absent from RequestIds; the first reset is TERMINATED; current/base link names the second. In response-unavailable cases, an after-handler hook runs exactly once on successful Reset, captures its real Run ID, substitutes Unavailable and is removed before replay. This models an unavailable successful response; it is not a claimed network packet-loss or process-crash experiment.

Controls pass: a different Reset request intentionally creates another run and terminates the previous current; reusing the original Start ID as Reset ID returns the existing unreset run. The latter proves which field the guard reads, but is **not** counted as another defect because separate cross-method request-ID namespaces were not promised.

Authoritative final overlay identity rerun: `evidence/final-functional.log` (select identity cases only; an obsolete recovery assertion in the same log is superseded below). Earlier full-config runs and exact UUID observations remain in [identity/observations.json](evidence/identity/observations.json). SQL file readback and forced reload establish persistence of the wrong identity, without claiming server-process restart.

### T-2 / CR-2: CAN histories are individually valid but fail Reset reconstruction

The loaded SDK v1.48.0 documents Update ID uniqueness over Namespace + Workflow ID + **Run ID** (`internal/internal_workflow_client.go:994-996`, copied in `evidence/history/sdk-update-id-contract.txt`). Supported execution:

1. Start A, successfully complete Update U, signal A to Continue-As-New B.
2. Successfully complete Update U in B; returned values contain the respective A/B Run IDs. Signal B to Continue-As-New C; C completes.
3. Reset explicit A at its first workflow-task completion, with default event reapplication. For the missing-current case, first publicly delete C and wait until current lookup returns NotFound.
4. Reset returns Internal: `Update ID reused-update-id is already present in mutable state`. The same exact request fails again; a dedicated shard-reload control also fails again.

`workflow_resetter.go:916-930` passes a nil Update registry and empty resource-dedup Run ID on the assumption that a consistent source cannot contain conflicting Update IDs. Its traversal spans several runs (`:725-911`). `MutableStateImpl.ApplyWorkflowExecutionUpdateAdmittedEvent` rejects the second admission (`:5735-5749`), before `persistToDB`. That is a compensating safety guard: it prevents ambiguous duplicate admission. It also means Reset cannot complete for this supported chain. Database base ResetRunId remains empty; current stays completed C, or stays missing after C's deletion. No acknowledged new run or silent data loss was observed.

Two controls isolate the mechanism: distinct Update IDs produce two admitted events in reset history; excluding Update events permits Reset with no admitted Updates. Exclusion changes requested semantics and is not recovery of the unchanged request. Subsequent healthy retries cannot repair the identifier collision. Repair policy must account for two independently valid inputs; silently dropping one cannot be assumed correct.

Final `evidence/history/final-history-tests.log` has five CAN observation cases passing their **observed-behavior assertions**: three rejection cases and two success controls. Three observed rejections count as one defect. The ordinary/missing-current cases use file SQLite; CloseShard uses a separately identified memory-backed cluster. Complete source/history/UUID/error evidence and earlier harness corrections are in [history/audit.md](evidence/history/audit.md).

[#6375](https://github.com/temporalio/temporal/issues/6375) concerns cross-CAN Update retry duplication, not this Reset reconstruction failure. [#6513](https://github.com/temporalio/temporal/pull/6513) fixes completed-Update lookup during conflict reapplication; Reset intentionally does not use that registry. Exact upstream searches found no matching Reset collision report, but this is limited novelty evidence, not proof that the problem is unknown or maintainer-confirmed.

## Phase 3 — persistence, uncertainty and recovery

| Reset path | Metadata atomic unit | Conditions and separate boundaries |
|---|---|---|
| Base = current | Current mutation + new execution snapshot + current replacement + tasks | Expected current, concrete record version, shard ownership; history appended separately |
| Base ≠ current | Base snapshot + current mutation + new snapshot + current replacement + tasks | One ConflictResolve metadata transaction with expected current and concrete versions; history separate |
| Current missing | **First** base-only UpdateBypassCurrent; **then** CreateBrandNew new run/current/tasks | Base bypass accepts absent or different current, not an atomic absent-current condition; later Create must reject a newly existing current |

Source: `workflow_resetter.go:368-504`; `workflow/transaction_impl.go:53-220`; SQL `execution.go:39-78,106-124,337-443,447-577`; Cassandra `mutable_state_store.go:388-493,602-918`. Both backends retain their actual ownership/concrete-state/current conditions. SQL row locking + checked update is one transaction; separating those statements into independent model actions would be incorrect. Cassandra uses a logged conditional batch for execution/current/task/shard records; history is a separate layer, not part of that metadata CAS.

Fork branch metadata is registered **before** reconstruction or the first reset history append (`workflow_resetter.go:518-545`; `history_manager.go:37-129`). SQL appends execution history before its shard-locked metadata transaction. An orphan branch or history append following a rejected metadata write is not itself an acknowledged workflow execution.

Failure classes must remain separate. ResourceExhausted/condition errors are definite metadata noncommit according to `common/persistence/error_type.go`; generic database commit failures and Cassandra timeout/no-response errors may have committed. `OperationPossiblySucceeded` notifies task processors for uncertain writes but the wrapper still returns the error (`transaction_impl.go:82,137,201`). Notification is not client success. Unknown write outcomes cause shard reacquisition, draining tracked operations and advancing durable RangeID before resuming (`shard/context_impl.go:1501-1549,2030-2151`). No standalone background action in Reset finishes an abandoned base-link/Create pair: retry re-enters Invoke, allocates another candidate and reconstructs it.

**Executed recovery schedule, final `evidence/recovery/recovery-complete.log`:** supported Start/complete A, Start/complete B, public Delete(B), wait for missing current; intercept the reset-specific Create and return ResourceExhausted before backend submission. Readback confirms base link `0e8a5435-338d-47be-bc97-47b5e074d049` but no such execution. Disable the fault, CloseShard, repeat the exact Reset request; response/current/base link all become `39d3e958-f3c7-4d85-86aa-387fed1cc6fb`. A public worker poll receives exactly that run, completion succeeds, and durable mutable state is COMPLETED. The base is then publicly deleted; after another shard close, the reset's eight-event history is unchanged/readable. This verifies rejection recovery and retained history under real SQLite transactions; it does not verify uncertain commit or process restart.

**Executed competing Start schedule, same log:** at SQL I/O concurrency two, gate reset Create after durable base link. Public Start commits `01a08805-7377-7060-a688-1839758cf437` before releasing the gate. The initial candidate `0449afd9-de45-4716-9f13-f958dab245e4` is absent. The original **public Reset call succeeds**, returning `3651deac-702a-4300-8f2c-78a36b5bf8b8`; competitor is TERMINATED and new current/base link match the response. After shard reload, the returned run is polled and completed. This is permitted Start → Reset ordering, not a lost update or forbidden overwrite.

The first BrandNew conflict is converted to Unavailable, and History's server interceptor retries the entire handler with the **same external request**. The first attempt releases/clears its leases; the next attempt sees and intentionally terminates the competitor using the ordinary atomic path. History server retry policy permits two attempts; the History client and frontend have further retry layers. Exact anchors: `history/handler.go:2291-2298`, `history/fx.go:266-270`, `service/fx.go:188`, `api/retry_util.go:12-17`, `common/util.go:55-56,225-228`, `common/rpc/interceptor/retry.go:36-44`, `client/history/retryable_client_gen.go:839-852`. Internal failure must not be mistaken for a client-visible failed operation.

## Phase 3 — reapplication, consumers and deletion

Reapplication preserves the original base branch token for suffix reads while prefix rebuild may use the returned rewritten base token (`workflow_resetter.go:139-142,518-563`). It follows only terminal Continue-As-New successor IDs, not ResetRunId or unrelated later Starts. A deleted successor truncates traversal; other lookup/read errors fail the operation (`:725-911`). Signals retain their payload/header/identity/RequestId/links; eligible accepted Updates become admissions, while accepted events without request payload rely on the preceding admission (`:962-1021`). Explicit exclusions, skipped cancellation/termination and intended reexecution are part of the contract, not missing-work findings.

The running current's freshly flushed events are reapplied only if the CAN walk reaches that current (`:166-209`). A current outside the chain does not supply arbitrary events. The broader visibility-based traversal TODO is not a promise to replay every historical run. Existing normal CAN/buffered-signal/exclusion tests passed.

Public Delete acknowledges an asynchronous deletion request, not completed storage cleanup (`api/deleteworkflow/api.go:24-98`; `deletemanager/delete_manager.go:91-115`). Active deletion waits for the close-transfer task acknowledgement (`transfer_queue_task_executor_base.go:245-307`). Shard deletion enqueues visibility/replication work, deletes the exact matching current pointer, deletes concrete mutable state and finally the history branch (`shard/context_impl.go:922-934,1040-1102`). SQL/Cassandra deletion conditions include target Run ID, so deleting a base cannot unconditionally remove a newer current.

Branch retention depends on registered history-tree references, not ResetRunId. `history_manager.go:132-211` computes retained ancestor prefixes from every other branch; SQL applies branch/range removal transactionally (`sql/history_store.go:334-379`), Cassandra uses a logged batch (`cassandra/history_store.go:268-287`). Fork registration precedes reapplication, and a surviving source branch already protects its inherited prefixes. An alleged read-compute-delete race needs a reachable schedule overcoming these protections.

**File-backed live-run control:** public Reset A → R, leave R running, capture R history, public Delete(A), wait for explicit A NotFound, compare R history including inherited prefix, then run its Activity and complete R. This passed on final source (`evidence/history/final-history-tests.log`, `TestAnalysisDeleteBasePreservesReset`). It strengthens the existing cleanup tests, which delete all runs and do not by themselves establish survival between deletions.

History scavenger is age-gated and checks the run's mutable state before deleting an orphan branch (`service/worker/scanner/history/scavenger.go:202-286`). Non-NotFound errors are not deletion permission. The pinned default minimum branch age is **60 days** (`common/dynamicconfig/constants.go:3549-3553`); optional retention verification only removes completed data older than retention plus buffer (`scavenger.go:328-378`). Scanner worker availability and age/retention conditions materially affect cleanup progress. No scanner-age experiment was executed.

Consumer distinctions: public history/SDK result following uses close-event NewExecutionRunId and branch/run pagination identity; it does not automatically follow ResetRunId. Child-completion recording can redirect a closed parent through ResetRunId up to its limit (`api/recordchildworkflowcompleted/api.go:28-63,101-107`). A missing redirected target can return NotFound, and the sender can treat missing parent as complete (`transfer_queue_active_task_executor.go:458-481`). This remains **CR-3**, not a confirmed new loss: an executable pending-child/intermediate-link/recovery scenario and compensation audit are still required, and [#10639](https://github.com/temporalio/temporal/issues/10639) already describes a pre-Reset closed-parent completion problem. GetCompletionEvent's missing-event error prevents some silent task acknowledgement but does not prove repair of this different redirect path.

## Explicit exclusions and findings disposition

| Observation/inference | Disposition and evidence |
|---|---|
| Temporary base link points to absent new run | Intentional before Create; no Reset success yet. Executed healthy retry recovered; no standalone bug count |
| Deleting current does not promote older run | Intended, full maintainer discussion in #4792; supported missing-current initial state |
| Reset terminates current installed by another operation | Allowed after a fresh observation/conditional ordinary transaction; competing Start experiment verifies permitted ordering |
| Distinct-base current termination emits callbacks | Explicitly intended in #6694; callback suppression is only appropriate for reset base/current carryover. Excluded review suspicion |
| Start-ID reused as Reset-ID returns old run | Identity-scope control; no independently established cross-method namespace guarantee, no extra defect |
| SQL SELECT lock then UPDATE is non-atomic | False: same transaction; #11713/#11714 are optimizations, not missing transaction repairs |
| An inverse orphan pointer is reached by ordinary Delete | Not demonstrated; #11596/#11774 direct-store cases differ from legitimately absent current |
| All Signal dedup state survives Reset | Not established: event RequestId and pendingSignalRequestedIDs restoration differ; already-open #4028 is retained as known source-review context, not rediscovered bug |
| Activity expiration/retry issue | #6952/#10671 already known and outside primary general Activity scope |
| Child-completion redirect loss | CR-3 remains for code-review/confirmation; no result inferred from one helper or intermediate record |
| CHASM migration/replication/queue-fairness concerns | Explicit scope exclusions; read only where they establish identity, backend or recovery contracts |

## Execution inventory and reproducibility

| Final evidence | Cases | Result and interpretation |
|---|---:|---|
| `evidence/recovery/baseline.log` | 27 existing leaf cases | PASS: full ResetWorkflowTestSuite, HistoryNodeCleanupSuite and ordinary WorkflowReset paths; names in `baseline-cases.json` |
| Identity cases in `evidence/final-functional.log` | 6 replay + 2 controls | Six final Run-ID equality failures demonstrate T-1; two controls PASS. No remaining identity setup failure |
| `evidence/recovery/recovery-complete.log` | 2 | PASS: rejected Create → retry → completion/base deletion; Start-winning interference → internal retry → completion |
| `evidence/history/final-history-tests.log` | 5 CAN + 1 deletion control | PASS observation assertions: three stable T-2 rejections, two CAN success controls, one live-reset survivor/completion control |

Thus the **16 focused cases** comprise **10 passing observation/control cases and 6 deliberately retained contract failures**, establishing two defects rather than nine. Passing an assertion that an operation rejects does not establish conformance. Root's earlier recovery test failures were harness assumptions, preserved and superseded: missing polling deadline; a blocked default-one I/O semaphore; assuming the first internal conflict must escape as public error. No such failure is counted as a product defect. Earlier 30-second public-deletion waits and shared-cluster CloseShard misuse were likewise corrected and rerun. Test-only style changes were rebuilt and retested; the final sources and checksums are archived under `evidence/test-sources/`.

Build from the recorded repository:

```sh
GOTMPDIR=/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/build-tmp GOMAXPROCS=16 CGO_ENABLED=0 go test -c -p 8 -tags test_dep -o /tmp/temporal-reset-analysis.test ./tests
GOMAXPROCS=16 /tmp/temporal-reset-analysis.test -test.v -test.parallel 8 -test.timeout 6m -persistenceType=sql -persistenceDriver=sqlite -test.run '^TestWorkflowResetTestSuite/TestAnalysis(ExactResetReplay|ResetStartIDCollision|SeparateResetControl)$'
GOMAXPROCS=16 /tmp/temporal-reset-analysis.test -test.v -test.parallel 2 -test.timeout 5m -persistenceType=sql -persistenceDriver=sqlite -test.run '^TestWorkflowResetTestSuite/TestAnalysisMissingCurrentRecovery$'
GOMAXPROCS=16 /tmp/temporal-reset-analysis.test -test.v -test.timeout 6m -persistenceType=sql -persistenceDriver=sqlite -test.run '^Test(ResetWorkflowTestSuite|WorkflowResetTestSuite)/(TestAnalysisCANUpdateIDReuse|TestAnalysisDeleteBasePreservesReset)$'
```

The first invocation is expected to exit nonzero at the six identity equality assertions on this pinned implementation. The other two assert recorded observations and should exit zero. Use [evidence/reproduce.sh](evidence/reproduce.sh) to build and capture commands/statuses locally. This does not submit any upstream changes. Repository-required `make lint-code-fast GOLANGCI_LINT_BASE_REV=HEAD GOLANGCI_LINT_FIX=false` is passed with exit 0 and zero lint issues (`evidence/lint-complete.log`); exact final status is included in `evidence/verification.json`.

## Phase 4 — formal handoff and unresolved questions

The 170-line Scenario brief selects five mechanisms, defines model/exclusion boundaries, proposes variables/actions/invariants and separates model-checkable, test-verifiable and code-review findings. Model-checkable rows are forward-looking combinations of delayed/uncertain writes, competing requests, history traversal and cleanup; they are not replays of closed historical fixes. Deterministic T-1/T-2 observations remain executable findings even if excluded from expensive standalone MC hunts.

| Priority question | What was checked and actual result | Exact remaining work |
|---|---|---|
| Q1: split writes and uncertain outcomes | Every transaction/error/retry layer source-audited; definite Create rejection recovered after shard reload through completion; successful-response-unavailable path demonstrates T-1 | Inject committed-but-unavailable base and Create writes separately, delayed completion, file-backed process restart, ownership reacquisition and final client/worker outcomes. No TLC assurance yet |
| Q2: Reset request identity | Full assignment/read chain plus six file-backed public replays; T-1 reproduced, controls differentiate administrative Reset and collision scope | Maintainer review/newness confirmation and eventual repair regression including scheduler callbacks; no promise of permanent dedup across arbitrary current replacement |
| Q3: competing operations | Exact current/record/RangeID conditions and retry layers; Start actually committed during paused SQL Create; same public Reset recovered in allowed order, returned run completed | Different-base competing Resets; default-one between-call winner schedule; delayed old-owner writes and backend-specific execution outside SQLite |
| Q4: CAN/reapplication | Eligibility/frontiers/branch identity checked; existing tests passed; T-2 stable across exact retry and reload, distinct/exclusion controls succeed | Formal trace validation; transient intermediate-run read errors/deletion races; define collision semantics for independently valid Update payloads; known Signal dedup context not newly executed |
| Q5: deletion/cleanup | Supported public deletion reaches missing current; exact RunID deletion guards; fork refs and scanner conditions; file-backed live-reset base-deletion control remains executable through completion | Fault/uncertainty during deletion, scanner age threshold cleanup, process restart and CR-3 child-completion recovery schedule; no new history-loss result |

For model and trace generation, emit public request identity, internal attempt/candidate, leased base/current, durable branch registration/history append, persistence mode/expected versions/RangeID, **actual** commit outcome, returned error, cache invalidation/reload, current/base-link readback, response receipt and final worker history. A pre-call exception is not committed-response loss; CloseShard is not process restart; an error string without durable readback is not a terminal outcome. Preserve eventual healthy persistence, required client/internal retries, retained source/history, worker availability and intentional deletion/retention as explicit progress assumptions. An unfinished model search must remain INCOMPLETE.

The remaining formal and backend schedules are concrete handoffs, not completed proof claims or evidence of absence of defects. Current tests establish the two reported behaviors and the specific successful recovery/deletion controls at the recorded revision/configurations.
