# Code Analysis Review: asterinas-private-futex-requeue

Reviewed both documents against their archived evidence and Asterinas commit `0c60537098f4c2949ad2d382aaf499de72263d76`. Coverage totals were independently reconciled with the discussion and patch inventories. Key scenario paths were checked against the local Asterinas source and pinned Linux reference. All 89 local links in the two documents resolve.

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Coverage Statistics | 5/5 | The report records 142 screened commits, 54 analyzed patches, 83 collected issues, and 33 deeply read issues with 98 comments, meeting the 30+ target. It separately accounts for 30 deeply read PRs and scope screening of all 109 archived open PRs. The inventories support these totals, and the 50 issues not deeply read are disclosed (`analysis-report.md:72`). |
| Scenarios | 5/5 | Four scenarios meet the 4–7 target. Each states its mechanism, historical and current evidence, affected paths, variables, actions, granularity, priority, and rationale. Registration, quota differences, moved-wait cleanup, and effects on later live waiters form a coherent protocol. Scenario 4 is explicitly a consequence of MC-1 rather than another independent defect (`modeling-brief.md:18`). |
| Evidence Quality | 5/5 | Source and reference revisions are fixed. Current leads cite exact source locations, while issue/PR discussions and identified commits establish historical context. All 54 selected patches exist and are ancestors of the source pin. The Linux manual/source discrepancy is explicitly identified, and source predictions are distinguished from measured incompatibility (`analysis-report.md:150`, `analysis-report.md:266`). |
| Model-Checkable Findings | 5/5 | Findings are explicitly classified as one model-checkable candidate, three test-verifiable leads, and one code-review item. MC-1 asks a bounded ownership question with both a reclamation obligation and a later live-waiter consequence. Historical fixes are not repackaged as new targets, and no formal or runtime confirmation is claimed (`modeling-brief.md:126`). |
| Modeling Brief Completeness | 5/5 | All seven required sections are present. Category B, finite bounds, state variables, actions, lock boundaries, timer/cleanup granularity, five extensions, eight property groups, fairness assumptions, and exclusions are specified. The report supplies F00–F10 controls and trace requirements. Original/current ownership and temporary ownership during transfer are preserved (`modeling-brief.md:75`, `analysis-report.md:230`). |
| False Positive Control | 5/5 | The report distinguishes 16 confirmed/acknowledged historical bug records, 3 design gaps, 2 uncertain reports, 2 disputed/false reports, and 10 feature/tooling discussions. Explicit exclusions explain compensating locks, wake flags, closure, identity checks, spurious success, and timer ownership. Unread records and out-of-scope issues are not counted as false positives (`analysis-report.md:79`, `analysis-report.md:208`). |
| Source Code Annotations | 5/5 | File:line citations appear throughout the scenarios, atomicity map, findings, invariants, and exclusions. Source aliases are defined and linked to concrete files. Checked references support the described behavior, including quota conversion, both migration paths, original-bucket cleanup, wake acceptance, and timer cancellation (`modeling-brief.md:14`, `analysis-report.md:40`). |

## Overall: 35/35

## Issues Found

- No material quality or completeness issues were found.
- Formal verification, Linux controls, and Asterinas runtime confirmation remain `NOT_RUN`, as clearly documented. This is an acceptable boundary for the code-analysis stage. The review does not establish that the candidate defects reproduce.

## Verdict: PASS
