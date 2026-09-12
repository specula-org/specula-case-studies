# temporal-reset Results

## Final Reports

- [Summary](summary.md) — Results, validation limits, run details, and resource usage
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
| CR-2 | [Read](confirmation/CR-2/investigation.md) | [Read](confirmation/CR-2/debate.md) | [test_bugCR-2_missing_current_retry.sh](repro/test_bugCR-2_missing_current_retry.sh) |
| CR-3 | [Read](confirmation/CR-3/investigation.md) | [Read](confirmation/CR-3/debate.md) | [test_bugCR-3_competing_start.sh](repro/test_bugCR-3_competing_start.sh) |
| CR-4 | [Read](confirmation/CR-4/investigation.md) | [Read](confirmation/CR-4/debate.md) | [test_bugCR-4_can_update_collision.sh](repro/test_bugCR-4_can_update_collision.sh) |
| CR-5 | [Read](confirmation/CR-5/investigation.md) | [Read](confirmation/CR-5/debate.md) | [test_bugCR-5_reset_staged_child_completion.sh](repro/test_bugCR-5_reset_staged_child_completion.sh) |
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_scanner_age.sh](repro/test_bugMC-1_scanner_age.sh) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_reset_retry_identity.sh](repro/test_bugMC-2_reset_retry_identity.sh) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)

## Troubleshooting

- Full pipeline log: [pipeline.log](../../pipeline.log)
