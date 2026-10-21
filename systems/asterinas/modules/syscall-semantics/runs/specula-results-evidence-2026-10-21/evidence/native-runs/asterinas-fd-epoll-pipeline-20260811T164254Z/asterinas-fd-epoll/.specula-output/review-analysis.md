# Code Analysis Review: asterinas-fd-epoll

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Coverage Statistics | 5/5 | Reports 156 commits screened, 30 significant patches inspected, 284 bug-labeled issues inventoried, **35 issues deeply read** with all 85 comments, and all 137 open PR titles screened with 12 inspected more closely. The 30+ deep-read target is met. |
| Scenarios | 5/5 | Six scenarios are grouped by mechanism and each supplies evidence, affected paths, variables, actions, action granularity, priority, and rationale. The 4-7 target is met. |
| Evidence Quality | 3/5 | The six current candidates have concrete source sequences, controls, Linux comparisons, and file:line evidence; sampled source ranges and all cited local commit OIDs were valid. Traceability is split across sections, however: only CA-3 names a related issue and no CA-1 through CA-6 section names a commit. Linux links also use moving `master` URLs. |
| Model-Checkable Findings | 5/5 | Findings are explicitly routed into 8 model-checkable, 4 test-verifiable, and 2 code-review-only items. The report distinguishes six current-source candidates from two baseline/control model questions and states that none is confirmed yet. |
| Modeling Brief Completeness | 5/5 | The 199-line brief identifies Category B and specifies bounded state, scenario variables/actions/granularity, model and do-not-model guidance, 8 extensions, 17 invariants, verification routing, and references. It is directly actionable for spec generation. |
| False Positive Control | 5/5 | The report documents controls and rejected claims, gives a disposition and reason for every deeply read issue, separates fixed history from current candidates, and isolates unsupported or excluded behavior. |
| Source Code Annotations | 5/5 | File:line ranges appear throughout both artifacts and cover state, synchronization, interleavings, tests, and compensating mechanisms. Representative checks for CA-1 through CA-6 matched the pinned source snapshot. |

## Overall: 33/35

## Issues Found

- Cross-link each CA-1 through CA-6 entry to its relevant issue/PR and fix commit, or state explicitly that no historical counterpart is known. The issue ledger and commit ledger at `analysis-report.md:501-578` do not currently provide per-candidate provenance, and the modeling brief contains no historical commit hashes.
- Pin the Linux comparison to a commit or release. Exact line claims against `torvalds/linux/blob/master` in `modeling-brief.md:37-97` and `analysis-report.md:638-641` will drift.
- Reconcile the patch count. `analysis-report.md:45` reports 30 significant patches, while `analysis-report.md:543-578` lists 30 core-path commits plus five additional inspected issue fixes. State 30 core/35 total if that is the intended accounting.
- Label MC-7 and MC-8 as baseline proof obligations, or move them out of “Findings Pending Verification.” The report already describes their compensating mechanisms at `analysis-report.md:9,322-353`, so counting them alongside the six current candidates can be read as inflating the finding count.
- Add line ranges to the key-source list in `modeling-brief.md:194-196`; the required ranges exist earlier, but the final handoff pointers omit them.

## Verdict: PASS
