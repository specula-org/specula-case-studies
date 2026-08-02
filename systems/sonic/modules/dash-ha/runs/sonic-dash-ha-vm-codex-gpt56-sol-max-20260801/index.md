# dash-ha Results

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
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_late_ack.rs](repro/test_bugMC-1_late_ack.rs) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_route_before_asic_ack.sh](repro/test_bugMC-2_route_before_asic_ack.sh) |
| MC-3 | [Read](confirmation/MC-3/investigation.md) | [Read](confirmation/MC-3/debate.md) | [test_bugMC-3_delayed_peer_state.rs](repro/test_bugMC-3_delayed_peer_state.rs) |
| MC-4 | [Read](confirmation/MC-4/investigation.md) | [Read](confirmation/MC-4/debate.md) | [test_bugMC-4_former_peer_repair.rs](repro/test_bugMC-4_former_peer_repair.rs) |
| MC-5 | [Read](confirmation/MC-5/investigation.md) | [Read](confirmation/MC-5/debate.md) | [test_bugMC-5_restart_pending_uuid.rs](repro/test_bugMC-5_restart_pending_uuid.rs) |
| MC-6 | [Read](confirmation/MC-6/investigation.md) | [Read](confirmation/MC-6/debate.md) | [test_bugMC-6_meta_reference_guard.cpp](repro/test_bugMC-6_meta_reference_guard.cpp) · [test_bugMC-6_parent_delete_live_scope.rs](repro/test_bugMC-6_parent_delete_live_scope.rs) |
| MC-7 | [Read](confirmation/MC-7/investigation.md) | [Read](confirmation/MC-7/debate.md) | [test_bugMC-7_vote_resets_switchover_budget.sh](repro/test_bugMC-7_vote_resets_switchover_budget.sh) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)

## Troubleshooting

- The raw pipeline log is intentionally excluded from this archive.
