# Evidence qualifications

- **FD/epoll:** the initial specification review was 24/40; the eventual 40/40 followed separate remediation sessions.
- **01a and 01b:** final reporting does not erase NEEDS_IMPROVEMENT review results. GLM MC-4 remained INCOMPLETE even though the earlier 01a run confirmed the same AST-03 entry.
- **Memfd:** the run was not blind. AST-75's discovery credit is disputed; keep its runtime result separate from that attribution question.
- **Futex:** AST-79 and AST-80 match upstream #3964. The native report's three-NEW tally is superseded. Key competing histories and cross-CPU clock comparability remain incomplete.
- **SCM_RIGHTS:** overlap coverage was limited and PEEK was outside default MC.cfg. Reproducing AST-32/36 does not establish complete concurrent-protocol validation.
- **Flock:** retain the bounded-check limits and the observer/timing assistance for AST-85.
- **Wait/reap:** AST-92/93 are sequential outcome observations. There are no implementation traces or native confirmation verdicts. The harness review remained NOT_APPROVED with an accepted residual; all 21 Asterinas run-level verdicts were inconclusive because of a dropped completion marker.
- **External AST-07/08:** kernel/device tests have different assumptions from ordinary unprivileged syscall reproductions. AST-07's later wrong answers were reproduced without kernel death; AST-08 requires the recorded DMA-device/vIOMMU setup.
- **Cost and dates:** missing costs are not zero; resume accounting is not fully reconciled. Campaign windows and TLPI intake dates are not exact discovery dates.
- **Tracker labels:** existing Confirmed and Fixed values are not downgraded. Use each page's source disposition and upstream repair assessment to interpret the underlying evidence.

The [source catalog](evidence/workspace/reports/asterinas-bug-findings-2026-08/README.md), [reproduction index](evidence/workspace/reports/asterinas-bug-findings-2026-08/reproduced.md), and [record audit](evidence/audit/records-audit-2026-10-19.md) preserve the detailed provenance. Original reports retain historical absolute links; use the generated finding pages and file inventory to locate the published subset.
