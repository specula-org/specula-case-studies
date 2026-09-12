# Code Analysis Review: temporal-history-queue

Reviewed both documents, supporting coverage/disposition ledgers, retained test evidence, and selected source paths at verified revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Independently checked the retained cursor SQLite snapshot's hash, integrity, and task 502, and confirmed that all four saved diagnostic test sources match the checkout. Existing test results were inspected; tests and model checking were not rerun for this review.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Coverage Statistics | 5/5 | Explicit, corroborated denominators: 41 core files / 16,720 LOC; 364 unique reviewed commit SHAs, including 314 keyword matches; 141 collected issues; **30 deeply read issues / 81 comments**, meeting the 30+ target. Also reports 387 screened open PRs and 62 deeply read PR discussions. Enumeration, deep reading, historical repairs, and current defects are distinguished (`analysis-report.md:25-41`; coverage manifests and ledgers). |
| Scenarios | 5/5 | **Five scenarios**, within the 4-7 target. Each specifies a causal mechanism, evidence, affected paths, modeling state, action granularity, and priority rationale. Publication uncertainty, cursor removal, checkpoint persistence, ownership handoff, and downstream ACK contracts form distinct, composable investigations (`modeling-brief.md:16-74`). |
| Evidence Quality | 4/5 | Findings have pinned source evidence, compensation analysis, and explicit verification status. CR-1 includes fault, healthy, and reconstruction controls plus retained SQLite evidence; historical ledgers pair SHAs with issue/PR numbers. However, some scenario-level historical references require searching appendices, especially Scenario 1. New unpublished findings appropriately have no invented upstream issue or fix commit. |
| Model-Checkable Findings | 5/5 | **Four forward-looking model-checkable questions (MC-1 through MC-4)** map to named properties and scenarios. Four test-verifiable entries and two code-review entries are separately identified. Closed fixes remain context, and CR-1 reconfirmation is explicitly excluded from MC-first discovery. MC discovery and reconfirmation are both correctly reported as zero (`modeling-brief.md:125-152`). |
| Modeling Brief Completeness | 5/5 | All required sections are present: Category A and scope/backend, variables, actions and atomic/split boundaries, model/exclusion rationale, **six extensions**, **nine named properties**, verification classifications, and reference pointers. Fairness assumptions, bounded exploration, and trace/negative-control requirements make the 164-line brief actionable (`modeling-brief.md:3-164`). |
| False Positive Control | 5/5 | All 30 issue dispositions reconcile: **8 confirmed historical/reproduction-backed reports, 4 acknowledged design limitations, 8 false-causal/user-error exclusions, and 10 uncertain**. Per-issue reasons and local compensations are documented. Fixed races, disputed diagnoses, scheduled/Cassandra mechanisms, duplicate delivery, and known DLQ limitations are kept distinct from current in-scope defects (`analysis-report.md:43-50,102-117`; issue ledgers; `evidence/reader-slice-audit.md:46-59`). |
| Source Code Annotations | 4/5 | Source locations appear throughout, and spot checks support the central CR-1/CR-2/CR-3 mechanisms. Minor annotation defects remain: an ambiguous Matching `task.go` reference conflicts with the brief's path convention, and the report frequently omits the colon or repeats only bare line numbers. |

## Overall: 33/35

## Issues Found

- **Minor — make Scenario 1's historical evidence directly traceable.** `modeling-brief.md:20` refers generically to publication/predecessor ledgers without naming a representative SHA, issue/PR, or exact ledger entry. Add the relevant commit/PR pair and a direct evidence pointer. Historical pairs already available elsewhere, such as `83fcd4262aa7` / #11353 and `c23064d3d5cf` / #11253 in `evidence/reader-history-ledger.md:8-9`, illustrate the desired traceability.
- **Minor — correct the Matching source pointer.** `modeling-brief.md:69` cites `task.go:373-403`, although line 12 assigns unqualified queue filenames to `service/history/queues/`. The intended file is `service/matching/task.go`, and the relevant `finish`/`finishInternal` implementation spans lines 373-397 at the pin. Use the full repository-relative path and corrected range.
- **Minor — normalize source annotations in the report.** Examples include `reader.go350-369` at `analysis-report.md:88` and `dynamicconfig/constants.go2263-2267` followed by bare ranges at lines 60-67. Use consistent `path:line` references and define the same path shorthand in the report as in the brief, so each document can be navigated independently.

The remaining full-engine adversarial reproduction, composed model checking, and trace validation are explicitly assigned future work. Their absence does not block this code-analysis handoff; CR-1's established result remains a native queue-boundary progress defect with durable recovery, not demonstrated end-user data loss.

## Verdict: PASS
