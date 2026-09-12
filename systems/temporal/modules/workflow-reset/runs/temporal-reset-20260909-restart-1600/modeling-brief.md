# Modeling Brief: Temporal Reset persistence and retry identity

## 1. System Overview

- **System/revision**: `temporalio/temporal`, Go, `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; repository `/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-reset`.
- **Category A (Distributed / Message-Passing)**: frontend/history RPCs, asynchronous tasks, durable database transactions and shard ownership determine outcomes; not BFT or a lock-free algorithm.
- **Scale**: 1,709 lines in Reset API/resetter; 6,955 including transaction wrapper, SQL execution, Cassandra mutable-state store and shard context. Additional rebuild/history/deletion modules are audited separately.
- **Reference**: durable workflow execution and the pinned public API contract, rather than a consensus paper. Reset forks a history prefix, reapplies selected later events, terminates a running current execution and installs a new current.
- **Concurrency**: per-run workflow leases, a short current-lookup lock, goroutine RPC/task processing, per-call shard I/O semaphore and durable RangeID/record-version conditions.
- **Distinct boundaries**: history fork registration, history append, execution metadata transaction, internal retry, public success and client receipt. Missing-current Reset adds two execution transactions.
- **Phase outcome**: executable findings and their assurance limits are in [analysis-report.md](analysis-report.md); no TLC or trace-validation pass is claimed in this Code Analysis phase.

## 2. Scenarios

### Scenario 1: A retry identity is replaced by callback source identity

**Mechanism**: an identity needed to deduplicate Reset is replaced by the original Start identity while rebuilding the new run.
**Evidence**:
- Historical: [#9479](https://github.com/temporalio/temporal/pull/9479) preserves Start identity for scheduler callbacks; [#2140](https://github.com/temporalio/temporal/issues/2140) establishes Reset request deduplication intent; [#11958](https://github.com/temporalio/temporal/issues/11958) discusses callback source/delivery identity separately.
- Code: `resetworkflow/api.go:124-136,180-215` reads current `CreateRequestId`, generates a fresh Run ID and omits the Reset ID from resetter arguments; `workflow_resetter.go:230-247` selects Start ID; `state_rebuilder.go:402-410` finds/falls back to it; `mutable_state_impl.go:2596-2612,3106-3123` persists it.
- Execution: six immediate exact-request replays, including verified discarded successful responses, create another run and terminate the first on file SQLite after forced database reload. These are six observations of **one** local defect, T-1.
**Affected code paths**: frontend Reset → `resetworkflow.Invoke` → `ResetWorkflow` → prepare/replay/rebuild → `ApplyWorkflowExecutionStartedEvent`/`AttachRequestID` → all three metadata modes → retry lookup.
**Suggested modeling approach**:
- Variables: `resetRequestId`, `startRequestId`, `callbackSourceId`, `candidateRun`, `createRequestId[run]`, `requestIds[run]`, `clientResult`.
- Actions: preserve actual identifier assignment; distinguish a new administrative Reset from another attempt of the same request, and server success from delivered response.
- Granularity: do not make a standalone MC hunt that merely rediscovers this deterministic assignment defect; retain identity in the common model because it changes recovery outcomes.
**Priority**: High.
**Rationale**: public retry can terminate a previously acknowledged run; correcting callback identity must preserve the callback contract.

### Scenario 2: A missing current requires an incomplete durable Reset before success

**Mechanism**: base-link mutation and new-current creation commit separately, and either persistence response can be uncertain.
**Evidence**:
- Historical: [#10926](https://github.com/temporalio/temporal/pull/10926) deliberately introduces base-first writes; [#10673](https://github.com/temporalio/temporal/pull/10673) is related bypass-current replication context, excluded from the single-cluster target.
- Code: `workflow_resetter.go:368-425`; SQL `execution.go:64-78,106-124,375-391`; Cassandra `mutable_state_store.go:388-493,888-918`; shard `context_impl.go:1501-1549,2030-2151`.
- Execution: public creation/deletion reaches missing current; a rejected Create leaves a durable base link and no candidate execution; healthy retry after `CloseShard` rewrites the link and the new workflow completes. This recovery probe uses real in-memory SQLite, not process-restart evidence.
**Affected code paths**: missing-current decision → fork/rebuild → UpdateBypassCurrent(base) → CreateBrandNew(reset) → error classification → lease release/reacquisition → public retry.
**Suggested modeling approach**:
- Variables: durable `runs`, `current`, `resetLink`, `history`, `branches`, `recordVersion`, `rangeId`; volatile request phase, leases, cached state and pending write result.
- Actions: separate definite rejection, commit with unavailable response, delayed completion and normal success; model each backend's actual transaction/ownership checks at the correct boundary.
- Granularity: fork registration and history append are separate from execution metadata; split the missing-current base transaction from Create, while retaining each ordinary metadata transaction atomically.
**Priority**: High.
**Rationale**: unresolved delayed-write/recovery combinations are suitable protocol questions; a temporary dangling link alone is intentional and must be permitted.

### Scenario 3: A stale missing-current decision meets a competing operation

**Mechanism**: the short current lookup can become stale before conditional execution writes; retry can choose the ordinary terminating Reset path.
**Evidence**:
- Historical: [#4066](https://github.com/temporalio/temporal/pull/4066) and [#4970](https://github.com/temporalio/temporal/pull/4970) explain current-lock scope; [#6694](https://github.com/temporalio/temporal/pull/6694) establishes intentional current replacement and distinct-base callback behavior.
- Code: cache `cache.go:463-493`; shard `context_impl.go:552-594,610-656,2189-2196`; SQL `execution.go:106-124,375-443,492-577`; history `handler.go:2291-2298`; `interceptor/retry.go:36-44`.
- Execution: default SQL I/O capacity one serializes a gate inside Create; with supported SQL capacity two, Start commits during the gate, initial Reset candidate is not created, and automatic whole-handler retry can terminate that Start and return a different Reset run successfully.
**Affected code paths**: Start/Reset current lookup and leases → per-call I/O admission → conditional write → converted Unavailable → server/client retries with the same request.
**Suggested modeling approach**:
- Variables: current observed by each attempt, per-run lease ownership, I/O slots, expected versions, internal attempt number and external request identity.
- Actions: competing Start, same-base/different-base Reset, release/reacquire between attempts, ordinary current termination and replacement.
- Granularity: default capacity one is per persistence call, not the entire Reset; SQL capacity two is a separate configuration, Cassandra is capped at one.
**Priority**: High.
**Rationale**: ordering and automatic retry determine whether termination is allowed; checking only the first internal transaction error misclassifies public success.

### Scenario 4: Reapplication combines histories with different identity scopes

**Mechanism**: events valid in separate Continue-As-New runs are combined into one reset run with one Update-ID map.
**Evidence**:
- Historical: [#6375](https://github.com/temporalio/temporal/issues/6375) discusses Update retry across CAN; [#6513](https://github.com/temporalio/temporal/pull/6513) fixes completed-Update lookup for conflict reapplication, not Reset's nil-registry path; [#5833](https://github.com/temporalio/temporal/pull/5833) records that intentional distinction.
- Code: `workflow_resetter.go:725-911` walks only surviving CAN successors; `916-1021` skips Update registry/resource dedup for Reset and converts eligible events to admissions; `mutable_state_impl.go:5735-5749` rejects an already-present Update ID.
- Execution: the focused CAN test exercises two successfully completed same-ID Updates, ordinary/missing-current Reset and distinct-ID/exclude-Update controls; exact results are in the report and `evidence/history/` (T-2).
**Affected code paths**: CAN closure/successor lookup → prefix rebuild → suffix/CAN reapply → Update admission → current termination commit or error/retry.
**Suggested modeling approach**:
- Variables: per-run CAN successor, event provenance `(run,event,version)`, Update ID/payload, prefix/suffix frontier, exclusion set and rebuilt Update map.
- Actions: admit/complete Update per run, CAN, delete successor, replay eligible suffix, reject conflicting admission; keep failure behavior instead of assuming rebuild always succeeds.
- Granularity: retain original base token for suffix traversal and optionally rewritten fork token for prefix; distinguish a missing run from transient lookup/read failure.
**Priority**: High.
**Rationale**: per-run identity and cross-run reconstruction interact directly; do not equate intentional work reexecution with duplicate API requests.

### Scenario 5: Registered history branches and deletion outlive execution attempts

**Mechanism**: fork references protect shared history independently of execution records and Reset links, while staged deletion and consumers can observe incomplete attempts.
**Evidence**:
- Historical: [#2484](https://github.com/temporalio/temporal/pull/2484) supports non-current deletion; [#4792](https://github.com/temporalio/temporal/issues/4792) confirms deletion does not promote an older run; [#10639](https://github.com/temporalio/temporal/issues/10639) is an unresolved closed-parent completion report, not a new Reset discovery.
- Code: `workflow_resetter.go:518-545`; `history_manager.go:37-211`; SQL `history_store.go:295-379`; shard `context_impl.go:922-934,1040-1102`; `recordchildworkflowcompleted/api.go:28-63,101-107`.
- Execution: existing cleanup tests pass; the added recovery probe deletes the base through the public API after successful reset/completion, closes the shard and checks that the reset history remains identical.
**Affected code paths**: fork metadata registration → execution attempt → conditional current deletion → mutable-state deletion → branch reference computation/deletion → history scanner/child-completion redirection.
**Suggested modeling approach**:
- Variables: registered branches/ancestor intervals, reachable runs, deletion stage, cleanup eligibility and pending completion delivery.
- Actions: public Delete acknowledgement separately from cleanup; branch registration/read/delete and selected scanner work at their actual boundaries.
- Granularity: no rule that ResetRunId itself keeps history alive; preserve branch-reference protection. Add child delivery only if a supported scenario establishes a distinct Reset-induced loss beyond #10639.
**Priority**: Medium.
**Rationale**: execution reachability and shared history require composition, but no history-loss defect is established by an intermediate link or by deleting all runs.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Three Reset persistence paths | Scenarios 2–3 have different atomicity/guards | Missing base+create versus atomic two-/three-run metadata transactions |
| Request/attempt/run/Start identities | Scenario 1 controls whether recovery creates more work | Separate identity fields; encode observed implementation before evaluating contract |
| Persisted history versus execution/current metadata | Scenarios 2 and 5 | Explicit fork/history/metadata steps and ownership fencing |
| Failed and ambiguous writes, cache loss and healthy retry | Scenarios 2–3 | Nondeterministic actual commit plus separate return; reload from durable state |
| CAN suffix frontier, Update map, exclusions | Scenario 4 | Source-run-aware events and per-run ID namespace; explicit rejection outcomes |
| Supported deletion and branch references | Scenario 5 | Public setup/actions; asynchronous stages and retained ancestor intervals |

Start with one namespace/workflow/shard, two active operations, two ownership epochs and enough distinct runs for A→B→C, deletion, competing Start and two reset attempts (six to seven IDs). Explore smaller configurations first; do not let finite ID exhaustion masquerade as a liveness failure. SQL and Cassandra need separate backend configurations.
Trace validation must map real public requests, selected identities, lookup results, branch tokens/frontiers, write mode/version, actual write outcome, cache release, retry, current/link readback and response receipt. Reuse the supplied Go tests and fault injectors; current diagnostic logs are evidence, not a validated TraceSpec.

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| A global `resetLink → existingRun` invariant | Violates intentional missing-current intermediate state; use acknowledged-result properties |
| Permanent request dedup after arbitrary current replacement/retention/deletion | Not established by the API's immediate retry contract |
| Generic Activity retry/expiration, multi-cluster replication, CHASM migration, queue fairness | Explicit scope boundary; #6952/#10671 and related replication repairs are reference context |
| Standalone recreation of historical fixes or the deterministic T-1 assignment error | No new protocol information; retain regression/code-review evidence and common identity state |
| Arbitrary database corruption or forced missing rows as reachability assumptions | Initial states must follow supported Start/CAN/Delete paths |
| Callback transport internals, all worker-versioning policies, payload serialization | Preserve relevant source identity/eligibility abstractly; implementation details use tests |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Request identity and attempt lifecycle | `resetReq`, `startId`, `createId`, `attempt`, `clientResult` | Retry versus intentional reset; callback source preservation | 1, 3 |
| Backend-aware durable transactions | `runs`, `current`, `links`, `recordVersion`, `rangeId`, `pendingWrite` | Split/atomic paths, uncertain return and fencing | 2, 3 |
| Leases and I/O admission | `leases`, `ioSlots`, `cached`, `observedCurrent` | Reachable overlap and error-driven reload | 2, 3 |
| Reapplication frontier | `canNext`, `sourceEvents`, `updateIds`, `exclude`, `replayPC` | Identity collision, eligibility and recovery | 4 |
| Branch/deletion lifecycle | `branches`, `ancestors`, `deleteStage`, `retained` | Reachable history protection and cleanup | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| CurrentExecutionConsistency | Safety | A committed current pointer names the corresponding durable run; competing current changes respect actual backend conditions | Standard durable-execution contract; 2, 3 |
| AcknowledgedResetExists | Safety | At success, returned run and required history exist with the requested base/prefix and eligible reapply result | 2, 4, 5 |
| ImmediateRetryIdentity | Safety | With no separate administrative replacement/deletion, an identical request retry does not create/terminate another run | 1; known T-1 test failure, not new MC discovery |
| FencedOldAttempt | Safety | A delayed old-owner metadata write cannot commit after newer durable ownership is established | 2, 3 |
| ReapplyProvenance | Safety | Successful reset includes exactly the permitted source events/identities; unrelated current suffix and excluded events are absent | 4 |
| ReachableHistoryRetained | Safety | Deleting another run cannot remove prefix/history needed by an acknowledged surviving reset | 5 |
| HealthyRetryRecovers | Liveness | With retained source and valid requested WFT boundary, available IDs/workers, eventual healthy DB, no new interference and fair required retries, requested Reset becomes executable or reaches a documented terminal rejection; persistent unexplained Internal is not recovery | 2–5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking question | Expected violation if defective | Scenario |
|---|---|---|---|
| MC-1 | Can a genuinely delayed or ambiguously completed base/create write, ownership recovery and retry yield an unavailable acknowledged run or prevent healthy recovery? | AcknowledgedResetExists / HealthyRetryRecovers | 2 |
| MC-2 | Can different-base concurrent resets or a competing Start combined with delayed writes produce an outcome outside permitted request ordering despite current/version conditions? | CurrentExecutionConsistency / FencedOldAttempt | 2, 3 |
| MC-3 | Can deletion/recovery during surviving CAN traversal or branch cleanup omit required events/history from an acknowledged reset, beyond explicit exclusion/deletion semantics? | ReapplyProvenance / ReachableHistoryRetained | 4, 5 |

### 6.2 Test-Verifiable

| ID | Finding/status | Further verification |
|---|---|---|
| T-1 | Local public-API conformance defect: Start ID replaces Reset dedup ID; six file-backed replay observations | Preserve regression, verify any repair against exact retry plus scheduler callback behavior; no maintainer confirmation/newness guarantee |
| T-2 | Valid per-run Update IDs collide when Reset folds a CAN chain; public execution and controls recorded in report | Preserve source histories, exact returned errors and retry/readback controls; assess reset contract and repair without blindly discarding distinct inputs |
| T-3 | Definite-rejection recovery and competing Start tested; internal write uncertainty/process restart still open | File-backed restart plus targeted ExecuteAndTimeout/delayed-commit schedules for each write; actual fault and durable readback required |

### 6.3 Code-Review-Only

| ID | Observation | Suggested action |
|---|---|---|
| CR-1 | One field currently serves callback source identity and Reset dedup identity (T-1) | Audit identifier assignments end to end; retain both contracts when repairing |
| CR-2 | Reset nil-registry assumption excludes conflicting Update IDs only within one run, although traversal spans runs (T-2) | Resolve source-event/Update-ID semantics explicitly; inspect full caller/callee outcome, not comment intent alone |
| CR-3 | Child-completion redirection follows intermediate ResetRunId and NotFound may be treated as parent gone | Verify supported pending-child scenario and compensation; distinguish known pre-Reset closed-parent drop (#10639); do not pre-prune this review candidate |

## 7. Reference Pointers

- Detailed evidence, counts, exclusions, commands and gaps: [analysis-report.md](analysis-report.md); [identity audit](evidence/identity/identity-audit.md); [persistence audit](evidence/persistence/persistence-audit.md); [history audit](evidence/history/audit.md).
- Main source: `service/history/api/resetworkflow/api.go:28-230`; `service/history/ndc/workflow_resetter.go:111-563,725-1128`; `service/history/workflow/transaction_impl.go:53-220`; backend and cleanup anchors above.
- Contract modules: `go.temporal.io/api@v1.63.5/workflowservice/v1/request_response.pb.go:4634-4643`; `go.temporal.io/sdk@v1.48.0/internal/internal_workflow_client.go:994-996` (Update ID scoped to Run ID).
- Tests/evidence: `evidence/identity/observations.json`, `evidence/recovery/`, `evidence/history/`, and `evidence/archaeology/`; historical fixes stay context rather than standalone hunt targets.
