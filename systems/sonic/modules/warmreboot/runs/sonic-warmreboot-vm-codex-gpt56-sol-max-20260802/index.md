# warmreboot Results

## Final Reports

- [Confirmation report](confirmed-bugs.md) — Confirmation results and supporting evidence
- [Severity report](bug-severity.md) — Impact assessment

> Availability means that a document exists. It does not imply review approval
> or confirmation of every finding.

## Supporting Analysis

| Step | Document | What it contains |
|---:|---|---|
| 1 | [Modeling brief](modeling-brief.md) | System model, Scenarios, and proposed invariants |
| 2 | [Analysis report](analysis-report.md) | Detailed source-code investigation |
| 3 | [Spec coverage](spec/brief-coverage.md) · [Instrumentation map](spec/instrumentation-spec.md) | How the analysis was translated into the model |
| 4 | [Validation changelog](spec/changelog.md) | Model corrections and validation history |
| 5 | [Model-checking report](spec/bug-report.md) | Candidate findings from model checking |

## Confirmation Details

| Finding | Investigation | Discussion | Reproduction |
|---|---|---|---|
| CR-5 | [Read](confirmation/CR-5/investigation.md) | [Read](confirmation/CR-5/debate.md) | Not available |
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_concurrent_reboot_cleanup.py](repro/test_bugMC-1_concurrent_reboot_cleanup.py) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_forced_nonquiescent_checkpoint.sh](repro/test_bugMC-2_forced_nonquiescent_checkpoint.sh) |
| MC-3 | [Read](confirmation/MC-3/investigation.md) | [Read](confirmation/MC-3/debate.md) | [test_bugMC-3_ready_before_fence.py](repro/test_bugMC-3_ready_before_fence.py) |
| MC-4 | [Read](confirmation/MC-4/investigation.md) | [Read](confirmation/MC-4/debate.md) | [test_bugMC-4_atomic_publication.sh](repro/test_bugMC-4_atomic_publication.sh) |
| MC-5 | [Read](confirmation/MC-5/investigation.md) | [Read](confirmation/MC-5/debate.md) | [test_bugMC-5_reconciled_before_flush.cpp](repro/test_bugMC-5_reconciled_before_flush.cpp) |
| MC-6 | [Read](confirmation/MC-6/investigation.md) | [Read](confirmation/MC-6/debate.md) | [test_bugMC-6_timeout_flag_mask.py](repro/test_bugMC-6_timeout_flag_mask.py) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)

## Troubleshooting

- The raw pipeline log is intentionally excluded from this archive.
