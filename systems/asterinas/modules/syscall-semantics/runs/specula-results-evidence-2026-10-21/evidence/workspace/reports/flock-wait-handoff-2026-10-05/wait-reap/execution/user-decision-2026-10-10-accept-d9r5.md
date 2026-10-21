# User acceptance of D9 revision 5 with a residual finding (2026-10-10)

The user accepted harness amendment D9 revision 5 for outcome-only runs:
- Workspace commit `c83ec47bc1a494d12faf28af9d4e218005c97c78`.
- Diff `harness-fix-2026-10-06/correction-v6-d9r5.diff`, sha256 `a834fb7037ba226df818c3961bd34cd189899725e54dcbcb7e31c8428912da0f`.

The independent review `harness-fix-2026-10-06/review-v6j.md` (sha256 `fba273f07b7fef596d257ae75a8e081551f37d48476955a343b839d1cc90a4a4`) returned NOT_APPROVED. Its only blocking finding is D9R5-S1 (Medium). The user overrode that verdict for this exact version. The override does not change the finding, which stays open.

## Accepted residual

D9R5-S1: `collect_outcome.py` decodes the whole log before it checks syscall records. If a placement line contains invalid UTF-8, the completed calls of that run are therefore discarded. Such a run is inconclusive either way. The defect only loses per-call detail inside a corrupted log. The fixture prints ASCII only, and the reviewer reproduced the defect with synthetic input.

## Conditions

- Every report of an outcome run under this receipt cites D9R5-S1 as an accepted residual and keeps the review verdict visible.
- Any run whose log fails UTF-8 decoding is reported as inconclusive and is not reinterpreted.
- Concurrency conclusions for WR-06..WR-10 use only runs whose report records the two waiters on different CPUs.
