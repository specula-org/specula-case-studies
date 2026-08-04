# ratis-server Results

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
| CR-2 | [Read](confirmation/CR-2/investigation.md) | [Read](confirmation/CR-2/debate.md) | [test_bugCR-2_known_ratis1995.out](repro/test_bugCR-2_known_ratis1995.out) · [test_bugCR-2_known_ratis1995.sh](repro/test_bugCR-2_known_ratis1995.sh) |
| CR-3 | [Read](confirmation/CR-3/investigation.md) | [Read](confirmation/CR-3/debate.md) | [test_bugCR-3_known_fixed.sh](repro/test_bugCR-3_known_fixed.sh) |
| CR-5 | [Read](confirmation/CR-5/investigation.md) | [Read](confirmation/CR-5/debate.md) | [test_bugCR-5_membership_guards.sh](repro/test_bugCR-5_membership_guards.sh) |
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_async_flush_failure.sh](repro/test_bugMC-1_async_flush_failure.sh) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_old_leader_lease_read.out](repro/test_bugMC-2_old_leader_lease_read.out) · [test_bugMC-2_old_leader_lease_read.sh](repro/test_bugMC-2_old_leader_lease_read.sh) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)

## Troubleshooting

- Full pipeline log: [pipeline.log](../../pipeline.log)
