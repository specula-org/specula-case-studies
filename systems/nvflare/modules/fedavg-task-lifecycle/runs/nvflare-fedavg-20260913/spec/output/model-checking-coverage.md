# Model-checking execution coverage

Counts are distinct states found, not a proof or a count of fully explored states. Periodic counts are the last logged lower bounds before a budget stop. Original Case A counterexamples remain evidence; revised runs check the remaining source-backed assertions.

| Run | Config | Distinct states | Queue | Depth | Result |
|---|---|---:|---:|---:|---|
| Standard | `MC.cfg` | 292,238,651 | 24,216,269 | 86 | 30-minute budget, no violation; periodic counts |
| hunt-bfs | [MC_hunt_s1_protected_input.cfg](hunt-bfs/MC_hunt_s1_protected_input/tlc.out) | 848,281 | 0 | 189 | complete-clean |
| hunt-bfs | [MC_hunt_s2_identity_history.cfg](hunt-bfs/MC_hunt_s2_identity_history/tlc.out) | 6,957,871 | 0 | 199 | complete-clean |
| hunt-bfs | [MC_hunt_s3_conversion_control.cfg](hunt-bfs/MC_hunt_s3_conversion_control/tlc.out) | 28,462,829 | 3,024,473 | 109 | budget-clean-incomplete; periodic counts |
| hunt-bfs | [MC_hunt_s3_metric_failure.cfg](hunt-bfs/MC_hunt_s3_metric_failure/tlc.out) | 29,332 | 295 | 81 | violation; Case C |
| hunt-bfs | [MC_hunt_s3_partial_parameters.cfg](hunt-bfs/MC_hunt_s3_partial_parameters/tlc.out) | 37,484 | 455 | 77 | violation; Case C |
| hunt-bfs | [MC_hunt_s4_cancel_overlap.cfg](hunt-bfs/MC_hunt_s4_cancel_overlap/tlc.out) | 20,845 | 605 | 55 | violation; Case A |
| hunt-bfs | [MC_hunt_s4_filter_retirement.cfg](hunt-bfs/MC_hunt_s4_filter_retirement/tlc.out) | 20,380 | 380 | 63 | violation; Case A |
| hunt-bfs | [MC_hunt_s4_prepare_error.cfg](hunt-bfs/MC_hunt_s4_prepare_error/tlc.out) | 18,656 | 298 | 61 | violation; Case A |
| hunt-bfs | [MC_hunt_s5_dead_policy.cfg](hunt-bfs/MC_hunt_s5_dead_policy/tlc.out) | 640,723 | 9,099 | 61 | violation; Case A |
| hunt-bfs | [MC_hunt_s5_progress.cfg](hunt-bfs/MC_hunt_s5_progress/tlc.out) | 3,459,013 | 682,842 | 36 | budget-clean-incomplete; periodic counts |
| hunt-bfs | [MC_hunt_s5_resilient.cfg](hunt-bfs/MC_hunt_s5_resilient/tlc.out) | 2,010,803 | 0 | 189 | complete-clean |
| hunt-revised-bfs | [MC_hunt_s3_parameter_values.cfg](hunt-revised-bfs/MC_hunt_s3_parameter_values/tlc.out) | 38,610 | 621 | 79 | violation; Case C |
| hunt-revised-bfs | [MC_hunt_s4_cancel_overlap.cfg](hunt-revised-bfs/MC_hunt_s4_cancel_overlap/tlc.out) | 1,216,029 | 0 | 190 | complete-clean |
| hunt-revised-bfs | [MC_hunt_s4_filter_retirement.cfg](hunt-revised-bfs/MC_hunt_s4_filter_retirement/tlc.out) | 338,221 | 0 | 189 | complete-clean |
| hunt-revised-bfs | [MC_hunt_s4_prepare_error.cfg](hunt-revised-bfs/MC_hunt_s4_prepare_error/tlc.out) | 252,925 | 0 | 189 | complete-clean |
| hunt-revised-bfs | [MC_hunt_s5_dead_policy.cfg](hunt-revised-bfs/MC_hunt_s5_dead_policy/tlc.out) | 6,690,779 | 0 | 198 | complete-clean |
