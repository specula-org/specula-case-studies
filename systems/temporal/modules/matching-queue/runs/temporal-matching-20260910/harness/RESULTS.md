# Current harness results

The active corpus contains 24 complete implementation traces; all pass strict canonical replay. Eight corrupted implementation controls are rejected. Coverage is 84/88 action types (85 priority base actions plus three root-validator actions), not product or interleaving coverage.

The real SQLite V2 fairness diagnostic reproduces the late-completion eviction defect; its window-closed control preserves B in the restart-boundary query. Matcher and History-result interfaces are controlled. The priority and fairness evidence have distinct scope.

Exact hashes, counts, commands, bounded-check results and remaining limitations are in `../spec/validation-report.md` and `../spec/output/continuation-20260911/`. Earlier Phase 2.5 results remain under logs/model-checks and are not substituted for current checks.
