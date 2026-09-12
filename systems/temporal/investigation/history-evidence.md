# Temporal history evidence for Specula target selection

Snapshot: 2026-09-09 UTC. Source checkout: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025` (main, 2026-09-08). This is a bounded target-selection investigation, not a complete bug archaeology or a new-bug report. No counterexample or code-level reproduction was run here. Upstream access was read-only.

## Coverage and method

- Nine GitHub search queries, with all available pages for each query, collected **642 distinct issue/PR records: 41 issues and 601 PRs**. Search domains were lost workflows, stuck persistence, speculative workflow tasks, queue acknowledgements, persistence fixes, Continue-As-New, reset, open fixes, and TLA.
- Screened titles of all **131 open PRs returned by the `is:open fix` query**. This is not a claim to have reviewed every open PR or every correctness fix: the keyword query also includes documentation, tests, and performance work and can miss differently worded fixes.
- Deeply read **30 selected records: 9 issues and 21 PRs**. For each, fetched and read the full body and all issue comments; for PRs, also fetched and read all reviews and inline review comments. Total discussion material: **30 issue comments, 67 reviews, 68 inline review comments**.
- Of the 21 deeply read PRs, **10 were merged, 10 were open, and 1 was closed without merging**. Of the 9 issues, 6 were open and 3 closed.
- Read the complete available file patches for **10 merged fixes**: 4354, 6134, 6308, 6394, 10578, 10605, 10673, 10926, 11048, 11570. Fetched all file patches for the other selected PRs as an audit artifact; do not count those as completely read code diffs.
- The checkout is shallow. Git log contains only the pinned head; **no claim of exhaustive commit mining is made**. Merge SHAs below come from the GitHub pull-request endpoint. An open PR's `merge_commit_sha` is a generated candidate and is NOT evidence of merging.
- These counts refer to this evidence report only. Deduplicate the selected record IDs below when combining coverage with other reports.

Deep-read IDs: `459, 584, 4354, 6134, 6308, 6375, 6394, 6952, 9021, 9118, 10050, 10578, 10605, 10671, 10673, 10841, 10926, 11048, 11254, 11432, 11570, 11713, 11714, 11733, 11734, 11774, 11791, 11810, 11869, 11968`.

Raw evidence: `evidence-history/search-*.json`, `evidence-history/<number>/{issue,issue-comments,pr,reviews,review-comments,files}.json`. Collection scripts preserve pagination with `gh api --paginate --slurp`. `evidence-history/inventory.json` contains search and deep-read inventories.

## Eight strongest examples

Historical fixed bugs below establish that the mechanism matters. They are **reference context, not proposed new findings or rollback-and-rediscover targets**. A fresh Specula campaign needs an additional, currently unexamined semantic interaction and an externally observable outcome.

### 1. Queue reader/write bypass races; existing TLA+ use

[PR #11570](https://github.com/temporalio/temporal/pull/11570), created 2026-08-14, merged **2026-08-15**, merge SHA `83b35dc3bac4ea05296154e0b50055026d200150`.

A concurrent write can directly hand tasks to the reader while a persistence read is in flight. The read can later return the same tasks after they have already been delivered and acknowledged. Deduplication against only the outstanding-task map no longer sees entries removed below the acknowledgement boundary; applying a stale empty read can also move the read boundary backwards. The final patch filters tasks at or below ack level, rejects backwards read updates, and enforces monotonic persisted ack level.

Evidence: the PR was approved by `yiminc` (GitHub MEMBER) and another contributor; it includes deterministic unit tests for stale reads, already-acked task reappearance, no-spin boundary, and persisted ack monotonicity. Its author explicitly reports **verification in a TLA+ model that was not checked in at that time**. This is direct prior art for Temporal using TLA+, not speculation based on architectural suitability. It supports modeling value but lowers novelty for a generic queue-ack campaign. Do not say Temporal lacks formal verification.

### 2. Fair queue can lose its wake-up path

[PR #11048](https://github.com/temporalio/temporal/pull/11048), created 2026-07-14, merged **2026-07-24**, SHA `f534e74e45fb188d92ab812e1a453d24b0428e09`.

A reader can see and acknowledge a freshly written task before the writer returns. While the writer pins the acknowledgement boundary, the task remains as an in-memory ack entry. The writer's duplicate merge then finds no unacked tasks, incorrectly collapses the read boundary, evicts the ack, and can leave no tasks or pending read to trigger future loading. The final fix preserves the read boundary when there are only acknowledgements and retains a defensive read trigger.

Evidence: merged, approved, with targeted `TestFairReaderReMergeOfCompletedWriteKeepsReadLevel`, which sequences the read/write/ack interaction and verifies that a subsequent write still reaches the matcher. The original author describes the logic as tricky. This is a useful liveness example, but #11570 explicitly relates its later priority-reader repair to this fix: avoid counting them as unrelated evidence families.

### 3. Continue-As-New breaks completion identity and stalls scheduled actions

[PR #10605](https://github.com/temporalio/temporal/pull/10605), created 2026-06-08, merged **2026-06-09**, SHA `093ab6505c4010c314adb7f7ed1873d50b05580b`.

A completion callback's original request identity was lost when the workflow continued as new. The later callback could not be matched to the scheduler's running action and was silently dropped; with buffered overlap, later actions could remain blocked even though the workflow had completed.

**Use the final diff, not the stale PR body, for the repair:** the merged code packs the request ID into the Nexus callback token/header, decodes it when invoking the callback, and preserves that token across run transitions. It does not implement the body-described change to `getCompletionCallbacksAsProtoSlice` in mutable state.

Evidence: multiple approvals including `yycptt` (MEMBER). Functional `TestScheduledWorkflowContinueAsNewCompletion` creates a scheduled workflow that continues once, uses BUFFER_ALL so progress requires observed completion, asserts multiple completed actions, and verifies identical callback headers in both runs. The author reports fail-before/pass-after. Particularly relevant to durable application-state protocols: state, identity, and deferred side effects cross a logical run boundary without any consensus algorithm being the main object of study.

### 4. Reset of a surviving old run fails after the current run is deleted

[PR #10926](https://github.com/temporalio/temporal/pull/10926), created 2026-07-06, merged **2026-07-15**, SHA `44de0057368a4f5c6bb2e36f7b5c8edf16301ff8`.

Reset unconditionally resolved a current execution, so resetting an explicitly identified older run failed with NotFound after a newer current run had been deleted. The fix allows the explicit-base case, follows the surviving Continue-As-New chain, and creates a replacement current execution.

Evidence: approvals and a review reporting local testing; unit tests distinguish a missing current record from transient persistence errors and validate persistence mode. The functional regression builds A→B→C, deletes C, resets A, verifies the reset linkage/current execution, and checks that a signal on surviving B is reapplied. The body additionally includes a file-backed SQLite manual reproduction.

The final diff explicitly documents a **two-call persistence path** when current is absent: update the base run with BypassCurrent, then BrandNew-create the reset run. This ordering is deliberate because the transaction interface does not atomically combine those operations. It is not itself proof of a bug; any future investigation must read retries, concurrency guards, and actual user-visible outcomes before making a claim.

### 5. The same legitimate orphan state breaks replication apply

[PR #10673](https://github.com/temporalio/temporal/pull/10673), created 2026-06-12, merged **2026-07-17**, SHA `afd1d83c121408f75a676d19db6045c0c26d9e4e`.

After Continue-As-New and deletion of the latest run, an old closed run can remain with no current-execution record. Force-replicating that surviving closed run previously errored repeatedly and went to DLQ. The merged patch applies the closed orphan through the bypass-current/zombie path, while retaining errors for running targets or a new-run-bearing update that needs a current record.

Evidence: approved and merged; three focused unit tests cover closed target, rebuilt closed target, and rejection of a running target. #10926's reviewer specifically says these two changes should go together so replication remains correct. The PR acknowledges that reapplication requiring the deleted current run can still fail; this is already disclosed known scope, not an undiscovered Specula finding.

### 6. Failed persistence mutates the retry input

[PR #10578](https://github.com/temporalio/temporal/pull/10578), created 2026-06-06, merged **2026-06-08**, SHA `2dae83847ecb594181e4b8e6021846ecd2c75083`.

Create/update/conflict-resolution incremented shared caller-owned HistorySize before the persistence write. A failure followed by retry of the same snapshot applied the increment twice. Workflow-ID reuse provided a real public trigger: BrandNew fails on an existing closed current row, then UpdateCurrent retries the same snapshot.

Evidence: opened by `yiminc` (MEMBER), approved and merged. Functional test compares the reused-ID run's size against a fresh run, using a small allowance for timestamp/task-ID encoding differences. Persistence tests remove an old clone-and-restore workaround so failed writes must leave the caller snapshot unchanged.

This is strong evidence of mutable/persistent rollback hazards, but its demonstrated consequence is incorrect reported history size. Do not inflate it into lost history or data corruption. It may be simpler to diagnose by ordinary code review than by model checking.

### 7. Speculative workflow-task lifetime differs from cached durable state

[PR #6308](https://github.com/temporalio/temporal/pull/6308), created 2024-07-18, merged **2024-07-19**, SHA `bd097bbdbef4a10f424e9ed41375f504ccf93225`.

A speculative workflow task disappears when workflow context is cleared/reloaded, while its in-memory timeout task could still run. Determining whether the timeout belonged to speculative work from reloaded mutable state was therefore wrong. The final repair derives this from the task category, avoids inappropriate reload, and removes the timeout on context clear.

Evidence: approved by `yycptt` (MEMBER) and another reviewer. Existing functional tests were used and an assertion on speculative timeout metrics was reinstated; the PR does not claim a new targeted crash-reproduction test. Adjacent merged fixes are [#4354](https://github.com/temporalio/temporal/pull/4354) (2023-05-18, `9a6edae08d86f628e25e8b3563860cf72d72be10`, speculative failure emits three events rather than one so next-batch ID was wrong) and [#6394](https://github.com/temporalio/temporal/pull/6394) (2024-08-09, `888b2a01b84d25a4081e5632519a376be627c11e`, speculative disappearance misclassified as stale mutable state). These support a real family of semantics, not three independent current vulnerabilities.

### 8. Update retry can cross Continue-As-New and execute again

[Issue #6375](https://github.com/temporalio/temporal/issues/6375), opened **2024-08-06**, still **open** at this snapshot. No merged repair was established here.

The reporter provided a TypeScript SDK test reproducer and traces: an update completes in the same workflow-task completion as Continue-As-New, an internal error causes retries, and a later retry reaches the new run and is delivered again. Discussion by `mfateev` (MEMBER) and `alexshtin` explains the distinction from signals: server errors intentionally discard some in-memory update state and rely on retries; piggybacking a normal first workflow task can permit the original update to be accepted even while retry later follows the new run.

Treat this as an **existing, publicly discussed identity/semantics limitation**, not a new target claim. It makes it essential to agree which identifiers are deduplicated across a run versus an entire chain and which externally acknowledged stage is durable before writing an exactly-once invariant.

## Open PRs and exclusions that constrain novelty

| Records | Snapshot status and evaluation |
|---|---|
| [#11968](https://github.com/temporalio/temporal/pull/11968) | Open, created 2026-09-08; proposes SignalWithStart dedup after the original run closes. Unit tests claimed; no reviews/comments at retrieval. Already submitted upstream; not novel evidence from Specula. |
| [#11733](https://github.com/temporalio/temporal/issues/11733), [#11734](https://github.com/temporalio/temporal/pull/11734) | Both open, created 2026-08-23; ambiguous History task-start response can leave work started but undelivered until timeout. PR retains the request ID only while the original worker poll remains active. Author's tests described; no maintainer reviews/comments at retrieval. Treat as reported/pending, not confirmed permanent loss. |
| [#10841](https://github.com/temporalio/temporal/issues/10841), [#11774](https://github.com/temporalio/temporal/pull/11774) | Issue open since 2026-06-25, PR open since 2026-08-25. Orphan current pointer causes SignalWithStart retry loop; original reporter gives database evidence and admin recovery. Origin of the orphan is suspected Cassandra resurrection, not established. PR adds Cassandra functional test and has unapproved review feedback about clocks and failover ordering. Do not claim ordinary Temporal crash itself creates this state. |
| [#6952](https://github.com/temporalio/temporal/issues/6952), [#10671](https://github.com/temporalio/temporal/pull/10671) | Maintainer-authored issue open since 2024-12-07; unreviewed PR open since 2026-06-12. Reset rewrites activity schedule time while retry expiration remains based on the old schedule. A known issue; proposed repair is not an accepted current guarantee. |
| [#11810](https://github.com/temporalio/temporal/pull/11810) | Open since 2026-08-26; SignalWithStart bypassing Continue-As-New backoff. Maintainer reviews explicitly call existing behavior an operational workaround and behavior change potentially breaking; request a rollout flag/metrics and a proper admin mitigation. Do not impose a universal no-early-wakeup invariant on existing code and report its deliberate behavior as a new bug. |
| [#11254](https://github.com/temporalio/temporal/pull/11254) | Open since 2026-07-23; duplicate Nexus-update callback registration while admitted but not sent. Detailed PR plus tests, but retrieved review evidence is automated, not a human maintainer acceptance; do not promote automated comments into confirmed findings. |
| [#11869](https://github.com/temporalio/temporal/issues/11869) | Open since 2026-08-31. Detailed PostgreSQL/v1 scheduler report: pending logical timer, missing physical task, refresh-tasks recovers it. No exact trigger and no comments at retrieval. Useful diagnostic lead only; not a confirmed causal bug or evidence that the same CHASM mechanism applies. |
| [#9021](https://github.com/temporalio/temporal/issues/9021) | Open since 2026-01-14. User reports deleted running-workflow history. Maintainer rejects the proposed namespace-cache causal path for existing namespaces and asks for evidence; investigation moved offline. Corruption symptom remains reported, proposed root cause unconfirmed. |
| [#9118](https://github.com/temporalio/temporal/issues/9118) | Closed 2026-02-19. Proposed crash-gap explanation explicitly rejected by developer; stopping workers can produce delayed redelivery until timeout. Reporter stopped seeing the problem after changing timeout configuration. **Exclude the claimed durability bug.** |
| [#459](https://github.com/temporalio/temporal/issues/459) | Closed 2020-10-21 as unreproducible/no further information; original environment was Cadence 0.11. Exclude as confirmed Temporal evidence. |
| [#584](https://github.com/temporalio/temporal/issues/584) | Closed 2021-01-28 as too old/no recurrence in CI. Historical report has lost event symptom, but no confirmed cause or fix; exclude from confirmed-bug totals. |
| [#11432](https://github.com/temporalio/temporal/pull/11432) | Open since 2026-08-06; test-only CHASM pure-task invalidation check and mutation tests. Explicit framework invariant/TODO and synthetic mutation are not a reproduced production bug. |
| [#11791](https://github.com/temporalio/temporal/pull/11791) | Created and closed 2026-08-26, **not merged**. Reports scheduler idle-task duplication and functional unit-engine reproduction, but no comments/reviews resolving closure. Do not infer accepted fix from closed status. |
| [#11713](https://github.com/temporalio/temporal/pull/11713), [#11714](https://github.com/temporalio/temporal/pull/11714) | Both open since 2026-08-21. SQL performance changes retaining locks/conditions: skip unchanged current row; fold condition check into update. The word Fixes links improvement issues and does not establish a concurrency bug. |
| [#10050](https://github.com/temporalio/temporal/pull/10050) | Open since 2026-04-24. Mark CQL statements idempotent for retry; maintainer notes RetryPolicy/speculative policy not configured, so flag may cause no actual retry. Avoid treating intended driver semantics as current configured behavior. |

One additional merged reference, [#6134](https://github.com/temporalio/temporal/pull/6134), merged 2024-07-08 at `d09f110fa454219e5d14dc1129dbd0e6410745b8`, repairs namespace replication queue cleanup blocked by disconnected-cluster ack state. It includes unit tests and maintainer review of inclusive/exclusive deletion boundaries. This is mainly distributed membership/cleanup context, lower priority for the user's proposed durable-application-logic focus.

## Implications for the parent assessment

1. Temporal offers credible durable-state modeling opportunities: ephemeral/durable workflow-task state, commit/rollback effects, run identity transitions, asynchronous task delivery, and retry identities. The evidence is stronger than merely saying it stores data.
2. Favor one narrow vertical semantic slice and a public-API/real-persistence reproduction boundary. A model of all Temporal services and features is not a sensible first experiment.
3. Existing sophisticated regression tests and explicit internal TLA+ use mean a broad model of textbook queue safety is unlikely to establish novelty. Better added value would come from a code-grounded interaction not already described by these fixed or pending reports.
4. No quantitative probability of discovering new bugs follows from the 10 historical repairs. This investigation found **zero new validated bugs**. It supports a high-value system and a plausible experiment, not a promised repeat of four findings.
5. Claim boundaries matter: task start acknowledgement, activity side effect, workflow completion, update admission, and update acceptance are different states. Timeout-delayed retry is not permanent task loss; a durable workflow does not imply exactly-once external side effects.
