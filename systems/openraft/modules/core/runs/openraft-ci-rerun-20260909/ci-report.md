# Incremental CI Report: openraft

Result: complete, no implementation bug confirmed for `15f927e1358d41ffc1297516f781029dbf8ca86a`.

Evidence: `harness/run.sh` passed 4 focused scenarios and TLC replayed all 4 traces (8 events total). `spec/output/Update_focused_round4.out` exhausted 314,780 generated / 74,438 distinct states, and `spec/output/MC_hunt_scenario2_io_incremental_round4.out` exhausted 3,322 generated / 1,081 distinct states. `spec/output/Update_full_simulation_round4.out` completed 160,000 traces / 14,381,960 states with no violation. `spec/output/Update_full_round4.out` was budget-limited at depth 17 after 84,024,319 generated / 17,476,123 distinct states with no violation reported.

Limits: the full update BFS did not exhaust the state space, and trace coverage remains narrow. Stage details are in `spec/changelog.md`, `spec/validation-status.json`, and `spec/bug-report.md`.
