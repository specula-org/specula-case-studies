# nanvix Results

## Final Reports

- [Confirmation report](confirmed-bugs.md) — Confirmation results and supporting evidence
- Severity report: Not available — Impact assessment

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
| CR-1 | [Read](confirmation/CR-1/investigation.md) | [Read](confirmation/CR-1/debate.md) | [test_bugCR-1_build.log](repro/test_bugCR-1_build.log) · [test_bugCR-1_join_reap_before_copy.rs](repro/test_bugCR-1_join_reap_before_copy.rs) · [test_bugCR-1_join_reap_before_copy.run.log](repro/test_bugCR-1_join_reap_before_copy.run.log) · [test_bugCR-1_join_reap_before_copy.sh](repro/test_bugCR-1_join_reap_before_copy.sh) |
| CR-10 | [Read](confirmation/CR-10/investigation.md) | [Read](confirmation/CR-10/debate.md) | [test_bugCR-10_control_mmio_fault_guest_console.log](repro/test_bugCR-10_control_mmio_fault_guest_console.log) · [test_bugCR-10_mmio_free_guest_console.log](repro/test_bugCR-10_mmio_free_guest_console.log) · [test_bugCR-10_mmio_free_uaf.rs](repro/test_bugCR-10_mmio_free_uaf.rs) · [test_bugCR-10_mmio_free_uaf.run.log](repro/test_bugCR-10_mmio_free_uaf.run.log) · [test_bugCR-10_mmio_free_uaf.sh](repro/test_bugCR-10_mmio_free_uaf.sh) |
| CR-11 | [Read](confirmation/CR-11/investigation.md) | [Read](confirmation/CR-11/debate.md) | [test_bugCR-11_build.log](repro/test_bugCR-11_build.log) · [test_bugCR-11_live_count_balance.rs](repro/test_bugCR-11_live_count_balance.rs) · [test_bugCR-11_live_count_balance.run.log](repro/test_bugCR-11_live_count_balance.run.log) |
| CR-2 | [Read](confirmation/CR-2/investigation.md) | [Read](confirmation/CR-2/debate.md) | [test_bugCR-2_reset_for_exec_drops_pending.sh](repro/test_bugCR-2_reset_for_exec_drops_pending.sh) |
| CR-3 | [Read](confirmation/CR-3/investigation.md) | [Read](confirmation/CR-3/debate.md) | [test_bugCR-3_async_signal_drop_mask_leak.rs](repro/test_bugCR-3_async_signal_drop_mask_leak.rs) · [test_bugCR-3_async_signal_drop_mask_leak.run.log](repro/test_bugCR-3_async_signal_drop_mask_leak.run.log) · [test_bugCR-3_async_signal_drop_mask_leak.sh](repro/test_bugCR-3_async_signal_drop_mask_leak.sh) |
| CR-4 | [Read](confirmation/CR-4/investigation.md) | [Read](confirmation/CR-4/debate.md) | [test_bugCR-4_mutex_hold_on_exit_defers_release.rs](repro/test_bugCR-4_mutex_hold_on_exit_defers_release.rs) · [test_bugCR-4_mutex_hold_on_exit_defers_release.run.log](repro/test_bugCR-4_mutex_hold_on_exit_defers_release.run.log) · [test_bugCR-4_mutex_hold_on_exit_defers_release.sh](repro/test_bugCR-4_mutex_hold_on_exit_defers_release.sh) |
| CR-5 | [Read](confirmation/CR-5/investigation.md) | [Read](confirmation/CR-5/debate.md) | [test_bugCR-5_cpu_bound_caught_signal.rs](repro/test_bugCR-5_cpu_bound_caught_signal.rs) · [test_bugCR-5_cpu_bound_caught_signal.run.log](repro/test_bugCR-5_cpu_bound_caught_signal.run.log) · [test_bugCR-5_cpu_bound_caught_signal.sh](repro/test_bugCR-5_cpu_bound_caught_signal.sh) |
| CR-6 | [Read](confirmation/CR-6/investigation.md) | [Read](confirmation/CR-6/debate.md) | [test_bugCR-6_recv_message_loss.rs](repro/test_bugCR-6_recv_message_loss.rs) |
| CR-7 | [Read](confirmation/CR-7/investigation.md) | [Read](confirmation/CR-7/debate.md) | [test_bugCR-7_build.log](repro/test_bugCR-7_build.log) · [test_bugCR-7_capctl_selfgrant.rs](repro/test_bugCR-7_capctl_selfgrant.rs) · [test_bugCR-7_capctl_selfgrant.run.log](repro/test_bugCR-7_capctl_selfgrant.run.log) · [test_bugCR-7_capctl_selfgrant.sh](repro/test_bugCR-7_capctl_selfgrant.sh) |
| CR-8 | [Read](confirmation/CR-8/investigation.md) | [Read](confirmation/CR-8/debate.md) | [test_bugCR-8_build.log](repro/test_bugCR-8_build.log) · [test_bugCR-8_fork_cap_inherit.rs](repro/test_bugCR-8_fork_cap_inherit.rs) · [test_bugCR-8_fork_cap_inherit.run.log](repro/test_bugCR-8_fork_cap_inherit.run.log) · [test_bugCR-8_fork_cap_inherit.sh](repro/test_bugCR-8_fork_cap_inherit.sh) |
| CR-9 | [Read](confirmation/CR-9/investigation.md) | [Read](confirmation/CR-9/debate.md) | [test_bugCR-9_condvar_drop_masked.build.log](repro/test_bugCR-9_condvar_drop_masked.build.log) · [test_bugCR-9_condvar_drop_masked.rs](repro/test_bugCR-9_condvar_drop_masked.rs) · [test_bugCR-9_condvar_drop_masked.run.log](repro/test_bugCR-9_condvar_drop_masked.run.log) |
| MC-1 | [Read](confirmation/MC-1/investigation.md) | [Read](confirmation/MC-1/debate.md) | [test_bugMC-1_build.log](repro/test_bugMC-1_build.log) · [test_bugMC-1_lost_wakeup_interrupted.rs](repro/test_bugMC-1_lost_wakeup_interrupted.rs) · [test_bugMC-1_lost_wakeup_interrupted.run.log](repro/test_bugMC-1_lost_wakeup_interrupted.run.log) · [test_bugMC-1_lost_wakeup_interrupted.sh](repro/test_bugMC-1_lost_wakeup_interrupted.sh) |
| MC-10a | [Read](confirmation/MC-10a/investigation.md) | [Read](confirmation/MC-10a/debate.md) | [test_bugMC-10a_build.log](repro/test_bugMC-10a_build.log) · [test_bugMC-10a_nested_sigsuspend_saved_mask.rs](repro/test_bugMC-10a_nested_sigsuspend_saved_mask.rs) · [test_bugMC-10a_nested_sigsuspend_saved_mask.run.log](repro/test_bugMC-10a_nested_sigsuspend_saved_mask.run.log) · [test_bugMC-10a_nested_sigsuspend_saved_mask.sh](repro/test_bugMC-10a_nested_sigsuspend_saved_mask.sh) |
| MC-10b | [Read](confirmation/MC-10b/investigation.md) | [Read](confirmation/MC-10b/debate.md) | [test_bugMC-10b_restart_attribution.c](repro/test_bugMC-10b_restart_attribution.c) |
| MC-2 | [Read](confirmation/MC-2/investigation.md) | [Read](confirmation/MC-2/debate.md) | [test_bugMC-2_build.log](repro/test_bugMC-2_build.log) · [test_bugMC-2_signal_starved_nonsuspended_sleeper.rs](repro/test_bugMC-2_signal_starved_nonsuspended_sleeper.rs) · [test_bugMC-2_signal_starved_nonsuspended_sleeper.run.log](repro/test_bugMC-2_signal_starved_nonsuspended_sleeper.run.log) · [test_bugMC-2_signal_starved_nonsuspended_sleeper.sh](repro/test_bugMC-2_signal_starved_nonsuspended_sleeper.sh) |
| MC-3 | [Read](confirmation/MC-3/investigation.md) | [Read](confirmation/MC-3/debate.md) | [test_bugMC-3_build.log](repro/test_bugMC-3_build.log) · [test_bugMC-3_terminated_thread_resumes.rs](repro/test_bugMC-3_terminated_thread_resumes.rs) · [test_bugMC-3_terminated_thread_resumes.run.log](repro/test_bugMC-3_terminated_thread_resumes.run.log) · [test_bugMC-3_terminated_thread_resumes.sh](repro/test_bugMC-3_terminated_thread_resumes.sh) |
| MC-4 | [Read](confirmation/MC-4/investigation.md) | [Read](confirmation/MC-4/debate.md) | [test_bugMC-4_do_exit_rendezvous_panic.sh](repro/test_bugMC-4_do_exit_rendezvous_panic.sh) · [test_bugMC-4_run.log](repro/test_bugMC-4_run.log) |
| MC-5 | [Read](confirmation/MC-5/investigation.md) | [Read](confirmation/MC-5/debate.md) | [test_bugMC-5_spurious_oom.rs](repro/test_bugMC-5_spurious_oom.rs) |
| MC-6 | [Read](confirmation/MC-6/investigation.md) | [Read](confirmation/MC-6/debate.md) | [test_bugMC-6_cond_wait_relock_interrupted.rs](repro/test_bugMC-6_cond_wait_relock_interrupted.rs) |
| MC-7 | [Read](confirmation/MC-7/investigation.md) | [Read](confirmation/MC-7/debate.md) | [test_bugMC-7_mutex_map_leak.sh](repro/test_bugMC-7_mutex_map_leak.sh) |
| MC-8 | [Read](confirmation/MC-8/investigation.md) | [Read](confirmation/MC-8/debate.md) | [test_bugMC-8_build.log](repro/test_bugMC-8_build.log) · [test_bugMC-8_default_terminate_ignores_mask.rs](repro/test_bugMC-8_default_terminate_ignores_mask.rs) · [test_bugMC-8_default_terminate_ignores_mask.sh](repro/test_bugMC-8_default_terminate_ignores_mask.sh) |
| MC-9 | [Read](confirmation/MC-9/investigation.md) | [Read](confirmation/MC-9/debate.md) | [test_bugMC-9_build.log](repro/test_bugMC-9_build.log) · [test_bugMC-9_immortal_pending.rs](repro/test_bugMC-9_immortal_pending.rs) · [test_bugMC-9_immortal_pending.run.log](repro/test_bugMC-9_immortal_pending.run.log) · [test_bugMC-9_immortal_pending.sh](repro/test_bugMC-9_immortal_pending.sh) |

## Technical Details

- TLA+ models: [base.tla](spec/base.tla) · [MC.tla](spec/MC.tla) · [Trace.tla](spec/Trace.tla)
- Harness guide: [INSTRUMENTATION.md](harness/INSTRUMENTATION.md)
- Repair history: [repair-ledger.md](spec/repair-ledger.md)

## Troubleshooting

- Full pipeline log: excluded from this curated record; preserved in the source archive.
