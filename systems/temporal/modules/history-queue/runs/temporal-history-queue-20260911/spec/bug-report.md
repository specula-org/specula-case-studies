# Bug Report — temporal-history-queue

## Summary

- **Validation status: INCOMPLETE; not converged.** Six complete implementation traces and eight negative controls pass, but the required 30-minute MC.cfg BFS did not exhaust its state space.
- Model-checking bugs established in this validation phase: **0**. This is not a no-bugs or safety verdict.
- Post-convergence scenarios/configs tested: **0/9**. Hunting was not started because its convergence precondition was unmet.
- Baseline last progress: **130,208,773 generated; 40,246,046 distinct; 36,081,667 queued; depth 13**. Exit **124** at the runtime limit. See [raw output](output/validation-20260911/MC-round2.log) and [machine-readable status](validation-status.json).
- Prior source finding CR-1 was reproduced with stronger real-executor/SQLite/readback/reload evidence; it is not reclassified as an MC-first finding. CR-2 accounting and CR-3 lifecycle controls are reported separately in [validation-report.md](validation-report.md).

## Not Reproduced

| Config | Exploration | Result |
|---|---|---|
| `MC.cfg` | 40,246,046 distinct at last progress, depth 13, 36,081,667 queued | INCOMPLETE; no invariant violation observed before timeout |
| `MC_hunt_s1_publication.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s2_coverage.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s2_cursor.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s2_progress.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s3_checkpoint.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s3_cleanup.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s4_ownership.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s5_responsibility.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |
| `MC_hunt_s5_terminal_contract.cfg` | Not run | Baseline did not converge; BFS/simulation hunt precondition unmet |

No `Bug N` entries or corresponding MC findings are emitted. `findings.json` deliberately includes the incomplete status alongside its empty findings list.

## Coverage and model repairs

See [changelog.md](changelog.md) for Case B repairs and layered trace debugging. No invariant was relaxed to conceal an implementation counterexample. The final MC input matches the frozen Round 2 input exactly.

The state explosion combines publication/fault/ownership interleavings, independent snapshot and checkpoint stages, reversible slice transformations, and finite object-identity choices. The growing frontier stayed shallow despite tens of millions of states. Repeating this unchanged oversized BFS or reducing fault bounds would not establish the missing interactions.

Completed explicit diagnostic schedules cover selected cursor/recovery, unknown publication/checkpoint, reordered snapshots/lost replies, late-DLQ effects, and widening/overlap. Their endpoints and safety checks passed at 26–72 states; two repair diagnostics also completed at8/11 states. These schedules are neither exhaustive hunting nor proof of the uncompleted cross-product. Full implementation traces remain absent for buffered/partial reads, uncertain workflow publication across full acquisition, concurrent shard snapshots, late executor callbacks, and terminal/obsolete/DLQ/worker endpoints.

The required loop remains at Phase 2. Preserve the current failure budgets and address the search representation/composition and outstanding fidelity gaps before claiming convergence. Only then run each hunting config's BFS and its required simulation follow-up.
