# Validation Review: asterinas-memfd-seal-mapping-admission

## Status

- Syntax: PASS
- MC: FAIL
- Ready for trace validation: YES

The MC status records four expected compatibility counterexamples. The standard convergence run and five protocol hunts pass. The known implementation defects remain observable and do not block trace validation.

The requested `validation-report.md` and optional `quick-mc.log` are absent. This review instead checks [bug-report.md](bug-report.md), the [recorded validation activity](../spec-validation.activity.jsonl), and [validation outputs](output/validation/mc-results.json). The source is pinned to `0c60537098f4c2949ad2d382aaf499de72263d76`. Current source/specification hashes, all 90 trace hashes, and all ten MC log hashes match their recorded evidence. The twelve removed exploration modules remain hash-matched in the documented archive. This review did not rerun TLC or either kernel.

All three modules, `base.tla`, `MC.tla`, and `Trace.tla`, passed parsing and semantic analysis. The validation activity records an explicit successful SANY check of `Trace.tla` and its `base` dependency. [MC_round1.out](output/validation/MC_round1.out) records successful processing of `MC` and `base`, followed by completed exploration.

`MC.cfg` explored 64,042 generated states and 40,745 distinct states to depth 157, with an empty queue and no enabled invariant violation or deadlock. Five protocol hunts also completed without violations. Four hunts stopped on these expected failures:

| Configurations | Violated predicates | Interpretation |
| --- | --- | --- |
| `MC_hunt_scenario1.cfg`, `MC_hunt_TV1a.cfg` | `ReadOnlyAdmissionCompatibility`, `ReadOnlyAdmissionAfterWrite` | Known AST-73: writable accounting rejects a valid shared read-only mapping after WRITE sealing. |
| `MC_hunt_TV1b.cfg` | `ReadOnlyAdmissionNoFalseBusy` | The same AST-73 tracking decision causes false EBUSY when adding WRITE after a post-FUTURE read-only mapping. |
| `MC_hunt_TV2.cfg` | `SealRejectedReplacement` | Known AST-75: a seal-rejected fixed replacement has already removed the old mapping. |

The pinned source retains the tracking decision after `check_writable` clears MAY_WRITE, and performs fixed-range removal before the seal check. These paths support the recorded counterexamples. No unexpected MC violation or timeout appears in the reviewed runs. Passing convergence checks do not establish the excluded compatibility properties.

Instrumentation is already implemented. The current corpus contains 4,201 events covering all 32 event types. [Trace acceptance](output/validation/trace-acceptance.json) records 82 direct passes and eight complete existential witnesses. Each witness violates only `TraceNotComplete` and ends at `l=10` after nine events. The corresponding universal replay failures reflect blocked speculative orderings. `Trace.cfg` enables `TraceMatched`, and `ValidatePostState` compares the complete action-specific record against the full base action.

## Next Steps

- Reuse the existing [harness instrumentation](../harness/INSTRUMENTATION.md). No prerequisite instrumentation remains for the current scope. Future captures must preserve separate seal observation/publication, atomic acquisition/denial, split/merge/drop, cursor, and TLB dispatch/completion boundaries. Keep exact RMW receipts, locked snapshots, stable owner identities, syscall results, and per-thread timeboxes.
- Replay ordinary traces with `Trace.cfg`. Use `../harness/config/TraceNoSealing.cfg` for `default-seal.ndjson`. Preserve both outcomes when using `TraceSearch.cfg`, and accept only a complete `TraceNotComplete` witness with unchanged state checks.
- Reconcile the pipeline's expected report path with the actual `bug-report.md` and `output/validation/` artifacts. Treat the earlier generation-stage `NOT_RUN` statements as historical. Retain the harness-stage `MmapFdMode` correspondence correction when selecting the model revision.
- Keep conclusions within the two-thread, three-page, bounded workloads and the ordinary TLB completion assumption. Trace correspondence does not verify a kernel fix or establish general Linux compatibility.

## Verdict: PASS

The current specification and existing instrumentation are ready for trace validation, and the saved corpus has already completed it. The missing report entry point is a nonblocking handoff issue. AST-73 and AST-75 remain known implementation failures.
