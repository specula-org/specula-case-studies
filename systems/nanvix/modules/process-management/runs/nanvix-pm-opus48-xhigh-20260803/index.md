# nanvix Results

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
| CR-1 | [Read](confirmation/CR-1/investigation.md) | [Read](confirmation/CR-1/debate.md) | [test_bugCR-1_take_earliest_ready_and_self_stop.rs](repro/test_bugCR-1_take_earliest_ready_and_self_stop.rs) |
| CR-2 | [Read](confirmation/CR-2/investigation.md) | [Read](confirmation/CR-2/debate.md) | [test_bugCR-2_rollback.sh](repro/test_bugCR-2_rollback.sh) |
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_reap_deferred_unreachable.sh](repro/test_bugMC-1_reap_deferred_unreachable.sh) |
| MC-10 | [Read](confirmation/MC-10/investigation.md) | [Read](confirmation/MC-10/debate.md) | [test_bugMC-10_put_mutex_destroy_held.rs](repro/test_bugMC-10_put_mutex_destroy_held.rs) |
| MC-11 | [Read](confirmation/MC-11/investigation.md) | [Read](confirmation/MC-11/debate.md) | [test_bugMC-11_put_cond_destroy_parked_waiter.rs](repro/test_bugMC-11_put_cond_destroy_parked_waiter.rs) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_join_lost_status.sh](repro/test_bugMC-2_join_lost_status.sh) |
| MC-3 | [Read](confirmation/MC-3/investigation.md) | [Read](confirmation/MC-3/debate.md) | [test_bugMC-3_orphaned_mutex.rs](repro/test_bugMC-3_orphaned_mutex.rs) |
| MC-4 | [Read](confirmation/MC-4/investigation.md) | [Read](confirmation/MC-4/debate.md) | [test_bugMC-4_masked_default_action_signal.sh](repro/test_bugMC-4_masked_default_action_signal.sh) |
| MC-5 | [Read](confirmation/MC-5/investigation.md) | [Read](confirmation/MC-5/debate.md) | [test_bugMC-5_undeliverable_caught_signal.sh](repro/test_bugMC-5_undeliverable_caught_signal.sh) |
| MC-6 | [Read](confirmation/MC-6/investigation.md) | [Read](confirmation/MC-6/debate.md) | [test_bugMC-6_sigsuspend_nested.sh](repro/test_bugMC-6_sigsuspend_nested.sh) · [test_bugMC-6_sigsuspend_nested_logic.rs](repro/test_bugMC-6_sigsuspend_nested_logic.rs) |
| MC-7 | [Read](confirmation/MC-7/investigation.md) | [Read](confirmation/MC-7/debate.md) | [test_bugMC-7_strand_pending.sh](repro/test_bugMC-7_strand_pending.sh) |
| MC-8 | [Read](confirmation/MC-8/investigation.md) | [Read](confirmation/MC-8/debate.md) | [test_bugMC-8_kill_zombie_signal.sh](repro/test_bugMC-8_kill_zombie_signal.sh) |
| MC-9 | [Read](confirmation/MC-9/investigation.md) | [Read](confirmation/MC-9/debate.md) | [test_bugMC-9_exec_deferred_reap_masks_refusal.rs](repro/test_bugMC-9_exec_deferred_reap_masks_refusal.rs) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)
- Repair history: [repair-ledger.md](spec/repair-ledger.md)

## Troubleshooting

- Full pipeline log: excluded from this curated record; preserved in the source archive.
