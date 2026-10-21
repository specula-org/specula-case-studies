# Controller decision on the validation acceptance contract

Decision date: 2026-10-06. Author: the flock lane controller, which holds the
run's writer role and the shared heavy lock for this stage. This answers
`spec/validation-controller-request.md`.

## Decision: option 1

Use the exact reviewed Category B acceptance contract for this campaign.
Do not add `PROPERTIES TraceMatched` to `Trace.cfg`, and do not use the stock
trace-validation parser or the stock parallel handler for these traces.

The contract is bound to these bytes:

| Input | SHA-256 |
|---|---|
| `Trace.tla` | `918b7c4afe353cf32e50bc01c598b621d7ffd667b4e8ff835d4ba78716c17abf` |
| `Trace.cfg` | `a3b384f0dd0c4155222692134581790b0f7097fbebb54c160bc24f114398a140` |
| `generation-checks/validate_trace.py` | `944aeb8ea4f6af4ca7070144a006a3451ad3d06f58992a5a922f26464b515f29` |
| `instrumentation-spec.md` | `beeec7c8d523d76299bee5beb9f136919465cffba680d716db95023217581f72` |

- Accepted: TLC exit 12 with only `TraceNoWitness` violated. The
  counterexample is the complete matching interleaving.
- Rejected (`trace_mismatch`): TLC completes the search with exit 0 and no
  error, so no interleaving consumes every event.
- Any timeout, other invariant violation or evaluation error is INCOMPLETE or
  an error. It is never an acceptance and never a rejection.

## Why this is not a new change

- No semantic input changes. The bytes above are the revision-1 suite
  installed after the corrective review gate.
- The installed method itself requires existential acceptance for Category B.
  `spec_generation/references/trace-spec-pattern.md` (lines 133 and 153–155)
  says that branches dying on non-real orderings is pruning, and that TLC
  continues until it finds the real ordering. The generic `TraceMatched`
  step contradicts that for branching searches. Spec review R3 showed that a
  stalled candidate makes `<>(all consumed)` fail even when another order
  matches completely.
- The independent native spec re-review (PASS 40/40, `review-specgen.md`
  sha256 `4064d119…`) examined these exact hashes and states: "Trace
  validation must use the documented adapter: raw TLC exit 12 for
  TraceNoWitness means a matching witness, while exhaustive exit 0 means no
  witness. The stock raw-output success parser has different semantics."

## Constraints for the remaining validation work

- Replay all 18 current traces with the adapter, one TLC process at a time,
  with at most a 3 GiB heap and 2 workers. This keeps the lane within its
  4 GiB TLC allocation. Record each adapter result and raw log.
- Run `MC.cfg` within its prescribed 30-minute bound, then the hunting
  configurations and any simulation follow-up the method requires, with the
  same limits. A run that hits its limit is time-limited, not passed.
- The v12 runtime attempt `harness/evidence/attempt-20261005T165124-821788448/`
  is the current harness evidence. The controller ran it with the worker's
  documented `bash harness/run.sh` after the harness phase. `harness/STATUS.md`
  and `harness/status.json` predate it and are stale. Do not overwrite them to
  claim harness completion. Describe the discrepancy in the validation
  outputs instead.
- Any semantic change to the model, configuration, TraceSpec, trace
  interpretation, oracle or harness still follows `corrective_review_gate`.
  Preserve old and new bytes, get an independent exact-version review, and
  close material findings before any dependent rerun. If that review is not
  available, return an incomplete status with the preserved request.
- C05, C06 and C11 model counterexamples are candidates for later disposition,
  not confirmed Asterinas bugs.

This decision is reported to the coordinator and the user in the lane result.
