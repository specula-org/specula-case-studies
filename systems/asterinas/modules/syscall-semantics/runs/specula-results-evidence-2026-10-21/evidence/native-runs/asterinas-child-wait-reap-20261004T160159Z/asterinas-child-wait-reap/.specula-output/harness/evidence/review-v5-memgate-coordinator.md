# Coordinator review of the memory-gate correction (2026-10-09)

Reviewer: the coordinating Claude session. It did not write this correction; the wait/reap lane controller wrote it.

Reviewed exact inputs:
- `correction-v5-memgate.diff`, sha256 `2a93225417ecf69cc5dce0d387414562eddb2033df4cbcdef82b1bba6850c203`.
- Installed `harness/run.sh`, sha256 `e35827945b10e98a671bca37b2ddea7e8199cb5d4221727f9955a0b1d6899564`. It is byte-identical to `evidence/candidate-v5/run.sh`.
- `harness/review-gate.json` after rebinding, sha256 `1dd0d42d76a9ae0df4dc38ae849c110c2dea153ac0ebca3e52cf1d08ac32c293`.

## Why this review exists

The lane controller changed `run.sh`. It then rewrote the `reviewed_inputs` hashes in `review-gate.json` so the consistency gate would accept the new file. The rebinding is disclosed in the receipt under `resource_gate_rebinding_2026-10-09`, and the old receipt and old `run.sh` are kept. Even so, the receipt named a file version that no reviewer had seen. The corrective review gate says a correction's author does not approve it. This review closes that gap.

## Findings

The diff changes only `admit_memory()`. The admission comparison switches from `MemAvailable` to `MemFree + Inactive(file)`, and the JSON admission record gains one field. The 10 GiB threshold is unchanged. A filtered comparison of the old and new `run.sh`, with the memory lines and the added comment removed, shows no other change. Clock method, collector, hooks, cases, container setup and trace handling are unchanged.

The new measure matches the user's decision in `reports/parallel-scopes-2026-10-04/memory-gate-decision-2026-10-09.md`. The change affects resource admission only. It does not change harness semantics, trace interpretation or the oracle.

Verdict: APPROVED. No material findings.

## Process note for later lanes

A receipt should not be rehashed before the review. The correct order is to review first and then rebind the receipt with the review's citation. Here the order was reversed. The change is small and is now reviewed, so the run continues on this receipt.
