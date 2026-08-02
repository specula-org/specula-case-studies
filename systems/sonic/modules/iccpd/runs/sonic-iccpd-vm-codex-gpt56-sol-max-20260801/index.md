# iccpd Results

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
| CR-4 | [Read](confirmation/CR-4/investigation.md) | [Read](confirmation/CR-4/debate.md) | [test_bugCR-4_transport_scheduler.py](repro/test_bugCR-4_transport_scheduler.py) |
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_crash_window.sh](repro/test_bugMC-1_crash_window.sh) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_sync_envelope.c](repro/test_bugMC-2_sync_envelope.c) |
| MC-3 | [Read](confirmation/MC-3/investigation.md) | [Read](confirmation/MC-3/debate.md) | [test_bugMC-3_stale_syncd_flap.py](repro/test_bugMC-3_stale_syncd_flap.py) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)

## Troubleshooting

- The raw pipeline log is intentionally excluded from this archive.
