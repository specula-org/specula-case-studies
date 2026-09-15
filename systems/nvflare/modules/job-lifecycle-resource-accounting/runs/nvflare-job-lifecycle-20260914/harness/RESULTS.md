# Harness result

Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

| Scenario | Pytest | Events | Trace replay | First unmatched event |
|---|---|---:|---|---|
| abort_completion | PASS | 233 | success | — |
| admission_exception | PASS | 576 | success | — |
| competition | PASS | 303 | success | — |
| delayed_start | PASS | 241 | success | — |

Observed 94/125 spec event types. See [coverage.json](coverage.json) for every untested action.

Pytest checks actual saved statuses, returned capacity, empty executor maps and one free per allocation. Historical replay failures are preserved with their model/capture repairs in spec/changelog.md; current replay status is shown above. Passing replay is finite conformance, not exhaustive correctness. See [INSTRUMENTATION.md](INSTRUMENTATION.md) for the precise source/model boundaries and rerun instructions.

Run: `cd .specula-output && bash harness/run.sh`. A nonzero result preserves unresolved replay failures.
