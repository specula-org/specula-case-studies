# fdb Results

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
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_overlapping_flush.sh](repro/test_bugMC-1_overlapping_flush.sh) · [test_bugMC-1_post_flush_relearn.sh](repro/test_bugMC-1_post_flush_relearn.sh) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_delayed_age.sh](repro/test_bugMC-2_delayed_age.sh) |
| MC-3 | [Read](confirmation/MC-3/investigation.md) | [Read](confirmation/MC-3/debate.md) | [test_bugMC-3_vtep_replacement.sh](repro/test_bugMC-3_vtep_replacement.sh) |
| MC-4 | [Read](confirmation/MC-4/investigation.md) | [Read](confirmation/MC-4/debate.md) | [test_bugMC-4_bridge_port_flush_guard.sh](repro/test_bugMC-4_bridge_port_flush_guard.sh) |
| MC-5 | [Read](confirmation/MC-5/investigation.md) | [Read](confirmation/MC-5/debate.md) | [test_bugMC-5_delayed_learn_mclag.sh](repro/test_bugMC-5_delayed_learn_mclag.sh) · [test_bugMC-5_move_incarnation.sh](repro/test_bugMC-5_move_incarnation.sh) · [test_bugMC-5_remote_age_retry.sh](repro/test_bugMC-5_remote_age_retry.sh) |
| MC-6 | [Read](confirmation/MC-6/investigation.md) | [Read](confirmation/MC-6/debate.md) | [test_bugMC-6_deferred_latest_intent.cpp](repro/test_bugMC-6_deferred_latest_intent.cpp) · [test_bugMC-6_deferred_latest_intent.sh](repro/test_bugMC-6_deferred_latest_intent.sh) |
| MC-7 | [Read](confirmation/MC-7/investigation.md) | [Read](confirmation/MC-7/debate.md) | [test_bugMC-7_startup_nhg_replay.cpp](repro/test_bugMC-7_startup_nhg_replay.cpp) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)
- Repair history: [repair-ledger.md](spec/repair-ledger.md)

## Troubleshooting

- The raw pipeline log is intentionally excluded from this archive.
