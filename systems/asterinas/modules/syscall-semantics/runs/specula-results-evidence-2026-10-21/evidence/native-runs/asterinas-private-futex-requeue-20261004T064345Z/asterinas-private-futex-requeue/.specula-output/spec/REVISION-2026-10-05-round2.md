# Futex suite revision for P2-heap and P2-callbacks

The round-2 findings in `review-specgen.round2.md` were the only input to this
revision. The approved brief and analysis remain unchanged. Source verification
uses Asterinas commit `0c60537098f4c2949ad2d382aaf499de72263d76`, tree
`4693fdec88cd7da14bed4f1541eba593f123059c`, under
`/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/source`.
The source checkout was read only. The working-tree baseline is round-1 commit
`f59cca904d60c5e418c8492d0e74b6e45fa6728e`. No commit was made in this round.

## P2-heap

`HeapHeads` selects every pending generation whose original deadline is minimal.
`TimerCollect` requires membership before either cancellation removal or expiry
collection. `TimerCollectEnd` uses the same set to decide whether a future head
ends the loop. Equal deadlines remain nondeterministic. This follows
`timer.rs:207-215,299-304`. Cancellation only stores a flag at lines 253-255 and
does not change the deadline. A cancelled node behind an earlier future timer
therefore remains in the heap. No deadline is replaced with zero on cancellation.

`TraceTimerCollect` invokes that action directly, in addition to checking the
saved collection identity and the complete post-state record. The corresponding
instrumentation row requires the actual `peek`/`pop` node, its unchanged deadline
ordering and the collection's saved sample.

## P2-callbacks

`TimerCollectEnd` transfers the collected vector to an invocation-owned slot in
`s.callbacks`. Its first generation names that slot until the vector drains.
`CallbackBatch(g)` identifies the invocation that owns a callback. This is the
base model's abstract execution context. Concrete trace contexts bind to these
slots separately. Every nonempty slot owns unique admitted generations, so this
representation introduces no new admission bound or unbounded invocation counter.
Empty collections can repeat without allocating slots.

`TimerCallbackUpgrade` requires the callback to be its vector's head. A successful
upgrade leaves it there until `TimerCallbackFinish` releases its guard/reference
and advances the vector. A failed upgrade returns immediately and advances in
the upgrade action. The other callback phases retain their original behavior.
This follows the synchronous loop at `timer.rs:220-221` and the return paths at
lines 262-281. Each invocation retains its vector while a later collection
replaces `collect.ready`. Different invocations may interleave after heap release.

Trace schema `private-futex-v3` adds `args.batch` to all six callback events and
the mandatory `pending` vector suffix to those events and `TimerCollectEnd`.
`batchOwners` retains `(pid,batch)` for each outstanding vector after the active
collection identity clears. Every callback phase checks the association. A
sequential timer stream cannot start another collection until its prior vector
drains. Other streams remain eligible. Finished traces must also drain these
vectors. The mapping explains how to capture or reconstruct the local suffix.

The three reviewer fixtures are schema-migrated copies in `generation-checks/`.
Their 74-event schedules, timeboxes and existing fields are unchanged. The
generator removes the added fields and asserts exact equality to the original
inputs. `ReviewRound2.tla` is equivalent to the reviewer's wrapper: it extends
`Trace` and overrides only the input filename through its configs. The original
review fixtures, configs, modules, logs and results are untouched.

The first-round valid/corrupted pair is regenerated with the same 76-event
schedules. Additional probes check equal deadlines, overlapping invocations,
same-batch overlap, wrong execution context, wrong batch identity and reuse of
a busy sequential context. These are synthetic histories, not kernel captures.

## Preserved contracts

All 57 primitive actions retain one direct trace wrapper, exact argument schema
and instrumentation row. Every wrapper requires full post-state equality. No
kernel action is silent. `MC.tla` and all 18 original configs are byte-identical
to the baseline. All eight brief section 5 properties, finite admission bounds,
symmetry, view, fairness configuration and `CHECK_DEADLOCK FALSE` remain intact.
TV-1 through TV-3 remain separate from MC-1 and its later live-migration check.
Saved-original-bucket cleanup at `futex.rs:124`, both migration counts and every
existing safety/liveness predicate are unchanged. The audit compares all other
base operators against the baseline and preserves round-1 evidence byte for byte.

## Reproduction and evidence interpretation

Run from the workspace root:

```sh
python3 spec/generation-checks/generate_traces.py --suffix=-round2
python3 spec/generation-checks/run_checks.py parse --suffix=-round2
python3 spec/generation-checks/run_checks.py trace --suffix=-round2
python3 spec/generation-checks/run_checks.py review --suffix=-round2
python3 spec/generation-checks/run_checks.py timer --suffix=-round2
python3 spec/generation-checks/run_checks.py mc --suffix=-round2
python3 spec/generation-checks/audit_suite.py --manifest
```

The runners use the round-1 Java and jars, `-Xmx2g`, two workers, one TLC process
at a time, `timeout 1200`, and metadata under `states/`. Every log records its
exact Java command. New logs and result records have a `-round2` suffix.
Existing logs are not overwritten. MC mode skips logged configurations. Use a
fresh suffix to repeat checks, regenerating the schema fixtures for that suffix.

Only a `TraceIncomplete` witness with all cursors exhausted and other checks
satisfied counts as acceptance. Rejection requires exhaustion of all reachable
prefix states with no such witness. A temporal failure alone is insufficient.
The rejected fixtures use disjoint timeboxes and finish with an empty queue.
An MC invariant violation is a model candidate, not runtime confirmation. A run
that reaches 1,200 seconds is `INCOMPLETE`, with the last reported distinct-state,
queue and depth values. Bounds are never reduced to obtain a completion result.

An initial SANY attempt found a token-spacing error in the new empty-sequence
comparison. `sany-base-initial-round2.log` retains that superseded diagnostic.
The subsequent `sany-*-round2.log` files parse all three corrected modules.

## Candidate histories

The five quota/return candidates are present again in the current logs.
`generation-checks/quota-evidence-round2.json` records their current summaries
and final call states. These histories admit no timer and cannot depend on the
changed collection or callback actions.

- `s2_quotas` and `s2_zero_wake` accept one wake with raw wake quota zero. The
  dispatch conversion at `syscall/futex.rs:105-109,146-150` supplies one, and
  `posix_thread/futex.rs:488-495` counts and removes the accepted notification.
- `s2_zero_move_same_bucket` moves one entry with raw move quota zero. The
  source changes the key and increments the count before the quota comparison
  at `posix_thread/futex.rs:502-508`.
- `s2_return_count` wakes one, moves one, and returns one. Extraction/appending
  follows `posix_thread/futex.rs:520-533`. The return is `Ok(nwakes)` at line 381.
- `s2_same_address` returns one after the shortcut at
  `posix_thread/futex.rs:353-354`. The expected processed count remains the
  original Linux oracle. No physical migration is invented.

These current histories follow the pinned implementation and preserve the
previous candidate interpretation. Kernel execution and Linux controls remain
`NOT RUN`. No invariant or transition was changed in response to a candidate.

The current `ResourceAccountingBalance` witness has 56 states. Its batch collects
generation 2 at state 20, ends at 21, starts its callback at 22, and drains the
vector at 29. The subsequent requeue extracts, changes and appends generation 2
to B at states 43-45 (`futex.rs:520-533`). Cleanup still searches saved bucket A
at states 50-51 (`futex.rs:124,477-482`). The miss produces `OK` at 53, followed
by closure and return at 54-55 (`futex.rs:125-130`, `wait.rs:244-248,278-281`).
At the violating state, B still owns generation 2 with one registration and zero
removals. Its local and callback strong references have drained. No timer-order
artifact is needed for this history.

The current `LiveMigrationExhaustion` witness has 93 states. Its old timer batch
also ends at 21 and drains at 29. After both old waits return, generations 3 and
4 enroll behind retained closed generation 2. State 80 snapshots cohort `{3,4}`.
States 81-82 reject the closed waker (`wait.rs:262-265`, `futex.rs:488-495`). The
operation wakes generation 3, then spends its migration quota on generation 2
at states 88-90 (`futex.rs:520-533`). Generation 4 remains at B when state 93
sets the existing exhaustion observer. There is no expiry, closure or independent
notification of this fresh cohort.

`generation-checks/ownership-evidence-round2.json` contains the current state
projections and explicit checks of every heap pop and callback start in both
histories. These configurations admit at most one timed WAIT, so the two order
restrictions cannot manufacture a new history. The same-bucket control completes
without violation in 57,330 distinct states. These are source-backed model
candidates, with runtime confirmation still unrun.

## Recorded MC outcomes

All 16 MC configurations were rerun with the final model. Six searches completed without violation, seven reported model candidates and three reached the 1,200-second limit. The incomplete counts below are the last reported progress values. They are not exhaustive results.

Command: `python3 spec/generation-checks/run_checks.py mc --suffix=-round2`. Each log records the exact Java invocation.

| Configuration | Outcome | Log |
|---|---|---|
| `MC.cfg` | INCOMPLETE. 21,264,677 distinct, 20,866,538 queued, depth 6. | [log](generation-checks/MC-round2.log) |
| `MC_hunt_completion.cfg` | INCOMPLETE. 2,018,117 distinct, 2,008,050 queued, depth 5. | [log](generation-checks/MC_hunt_completion-round2.log) |
| `MC_hunt_s1_mismatch.cfg` | Complete without violation. 31 distinct states. | [log](generation-checks/MC_hunt_s1_mismatch-round2.log) |
| `MC_hunt_s1_registration.cfg` | Complete without violation. 289 distinct states. | [log](generation-checks/MC_hunt_s1_registration-round2.log) |
| `MC_hunt_s2_quotas.cfg` | Candidate: `RequeueQuotaAndResult`. 19 states (18 transitions). | [log](generation-checks/MC_hunt_s2_quotas-round2.log) |
| `MC_hunt_s2_return_count.cfg` | Candidate: `RequeueReturnCount`. 30 states (29 transitions). | [log](generation-checks/MC_hunt_s2_return_count-round2.log) |
| `MC_hunt_s2_same_address.cfg` | Candidate: `RequeueReturnCount`. 24 states (23 transitions). | [log](generation-checks/MC_hunt_s2_same_address-round2.log) |
| `MC_hunt_s2_unrelated_first.cfg` | Complete without violation. 1,390 distinct states. | [log](generation-checks/MC_hunt_s2_unrelated_first-round2.log) |
| `MC_hunt_s2_wake_zero_control.cfg` | Complete without violation. 620 distinct states. | [log](generation-checks/MC_hunt_s2_wake_zero_control-round2.log) |
| `MC_hunt_s2_zero_move_cross_bucket.cfg` | Complete without violation. 772 distinct states. | [log](generation-checks/MC_hunt_s2_zero_move_cross_bucket-round2.log) |
| `MC_hunt_s2_zero_move_same_bucket.cfg` | Candidate: `RequeueMoveQuota`. 22 states (21 transitions). | [log](generation-checks/MC_hunt_s2_zero_move_same_bucket-round2.log) |
| `MC_hunt_s2_zero_wake.cfg` | Candidate: `RequeueWakeQuota`. 20 states (19 transitions). | [log](generation-checks/MC_hunt_s2_zero_wake-round2.log) |
| `MC_hunt_s3_opposite.cfg` | INCOMPLETE. 5,566,834 distinct, 1,008,198 queued, depth 82. | [log](generation-checks/MC_hunt_s3_opposite-round2.log) |
| `MC_hunt_s3_owner.cfg` | Candidate: `ResourceAccountingBalance`. 56 states (55 transitions). | [log](generation-checks/MC_hunt_s3_owner-round2.log) |
| `MC_hunt_s3_same_bucket.cfg` | Complete without violation. 57,330 distinct states. | [log](generation-checks/MC_hunt_s3_same_bucket-round2.log) |
| `MC_hunt_s4_live_migration.cfg` | Candidate: `LiveMigrationExhaustion`. 93 states (92 transitions). | [log](generation-checks/MC_hunt_s4_live_migration-round2.log) |

## Recorded synthetic replay outcomes

| Fixture | Result | Reachable states | Log |
|---|---|---|---|
| `trace-valid` | ACCEPTED | 77 | [log](generation-checks/trace-valid-round2.log) |
| `trace-corrupted` | REJECTED | 29 | [log](generation-checks/trace-corrupted-round2.log) |
| `review-control` | ACCEPTED | 75 | [log](generation-checks/review-control-round2.log) |
| `review-heap-reversed` | REJECTED | 29 | [log](generation-checks/review-heap-reversed-round2.log) |
| `review-callbacks-reversed` | REJECTED | 32 | [log](generation-checks/review-callbacks-reversed-round2.log) |
| `probe-batches-overlap` | ACCEPTED | 77 | [log](generation-checks/probe-batches-overlap-round2.log) |
| `probe-same-context-overlap` | REJECTED | 32 | [log](generation-checks/probe-same-context-overlap-round2.log) |
| `probe-callback-wrong-batch` | REJECTED | 32 | [log](generation-checks/probe-callback-wrong-batch-round2.log) |
| `probe-callback-wrong-context` | REJECTED | 32 | [log](generation-checks/probe-callback-wrong-context-round2.log) |
| `probe-callbacks-overlap` | REJECTED | 33 | [log](generation-checks/probe-callbacks-overlap-round2.log) |
| `probe-equal-deadlines` | ACCEPTED | 75 | [log](generation-checks/probe-equal-deadlines-round2.log) |

`generation-checks/replay-evidence-round2.json` records the final cursors and the first unmatched event for each rejection. All rejected graphs have zero states left on the queue. The generator verifies that stripping the new schema fields reproduces all five original fixtures exactly.

## Changed files

The following paths are relative to the workspace root. The preexisting untracked
`spec/review-specgen.round2.md` and `spec/review-checks-round2/` remain unchanged
and are inputs, not additions by this revision. Ignored TLC metadata remains
under `states/`.

| File | Change and reason |
|---|---|
| `spec/REVISION-2026-10-05-round2.md` | This record explains both fixes, source-backed candidates, validation and every changed file. |
| `spec/Trace.tla` | Both corrections apply through direct base wrappers. P2-callbacks adds v3 batch ownership and mandatory pending-vector checks. |
| `spec/base.tla` | P2-heap restricts every pop to a heap head. P2-callbacks preserves and drains each invocation vector in order. |
| `spec/brief-coverage.md` | The coverage record ties both fixes to the existing scenarios and records the current verification limits. |
| `spec/generation-checks.txt` | The check record reports commands, logs and outcomes for both corrections. |
| `spec/generation-checks/MC-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_completion-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s1_mismatch-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s1_registration-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_quotas-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_return_count-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_same_address-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_unrelated_first-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_wake_zero_control-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_zero_move_cross_bucket-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_zero_move_same_bucket-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s2_zero_wake-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s3_opposite-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s3_owner-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s3_same_bucket-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/MC_hunt_s4_live_migration-round2.log` | This log records a fresh R5 search with the original configuration and both corrections loaded. |
| `spec/generation-checks/ReviewRound2.tla` | This wrapper preserves the reviewer's filename-only override for R4. |
| `spec/generation-checks/audit-initial-round2.log` | This log preserves the first successful contract audit after both fixes. |
| `spec/generation-checks/audit-round2.log` | This log records the final R7 contract and artifact-hash audit. |
| `spec/generation-checks/audit_suite.py` | The audit checks both fixes and verifies that unrelated operators, configurations, properties and round-1 evidence are preserved. |
| `spec/generation-checks/corrupted-round2.ndjson` | This fixture preserves the round-1 R6 schedule and old fields with the required v3 callback fields. |
| `spec/generation-checks/fixtures-round2.log` | This log records deterministic fixture generation and preservation of the original schedules. |
| `spec/generation-checks/generate_traces.py` | The generator migrates existing fixtures without changing their schedules and creates focused order and ownership probes. |
| `spec/generation-checks/mc-runner-round2.log` | This log records sequential R5 execution without changing bounds or overlapping TLC processes. |
| `spec/generation-checks/ownership-evidence-round2.json` | This file records current ownership and live-migration histories and checks their heap pops and callback starts. |
| `spec/generation-checks/probe-batches-overlap-round2.log` | This log records the named focused probe for P2-heap or P2-callbacks. |
| `spec/generation-checks/probe-batches-overlap-round2.ndjson` | This synthetic fixture exercises the named heap-order or callback-ownership boundary. |
| `spec/generation-checks/probe-callback-wrong-batch-round2.log` | This log records the named focused probe for P2-heap or P2-callbacks. |
| `spec/generation-checks/probe-callback-wrong-batch-round2.ndjson` | This synthetic fixture exercises the named heap-order or callback-ownership boundary. |
| `spec/generation-checks/probe-callback-wrong-context-round2.log` | This log records the named focused probe for P2-heap or P2-callbacks. |
| `spec/generation-checks/probe-callback-wrong-context-round2.ndjson` | This synthetic fixture exercises the named heap-order or callback-ownership boundary. |
| `spec/generation-checks/probe-callbacks-overlap-round2.log` | This log records the named focused probe for P2-heap or P2-callbacks. |
| `spec/generation-checks/probe-callbacks-overlap-round2.ndjson` | This synthetic fixture exercises the named heap-order or callback-ownership boundary. |
| `spec/generation-checks/probe-equal-deadlines-round2.log` | This log records the named focused probe for P2-heap or P2-callbacks. |
| `spec/generation-checks/probe-equal-deadlines-round2.ndjson` | This synthetic fixture exercises the named heap-order or callback-ownership boundary. |
| `spec/generation-checks/probe-same-context-overlap-round2.log` | This log records the named focused probe for P2-heap or P2-callbacks. |
| `spec/generation-checks/probe-same-context-overlap-round2.ndjson` | This synthetic fixture exercises the named heap-order or callback-ownership boundary. |
| `spec/generation-checks/probes-round2.json` | This file declares the expected results of the focused heap-order and callback-ownership probes. |
| `spec/generation-checks/quota-evidence-round2.json` | This file records the current quota candidates and their call states, which do not involve the changed timer paths. |
| `spec/generation-checks/replay-evidence-round2.json` | This file records complete cursors or the first unmatched event and exhausted queues for R4, R6 and the focused probes. |
| `spec/generation-checks/results-round2.json` | This file records every TLC command, outcome and exploration count for the current suite. |
| `spec/generation-checks/review-callbacks-reversed-round2.cfg` | This config preserves the reviewer's checks and selects the migrated R4 fixture. |
| `spec/generation-checks/review-callbacks-reversed-round2.log` | This log records the R4 acceptance or rejection of a reviewer order fixture. |
| `spec/generation-checks/review-callbacks-reversed-round2.ndjson` | This v3 fixture preserves the reviewer's schedule and old fields while adding P2-callbacks capture fields. |
| `spec/generation-checks/review-control-round2.cfg` | This config preserves the reviewer's checks and selects the migrated R4 fixture. |
| `spec/generation-checks/review-control-round2.log` | This log records the R4 acceptance or rejection of a reviewer order fixture. |
| `spec/generation-checks/review-control-round2.ndjson` | This v3 fixture preserves the reviewer's schedule and old fields while adding P2-callbacks capture fields. |
| `spec/generation-checks/review-heap-reversed-round2.cfg` | This config preserves the reviewer's checks and selects the migrated R4 fixture. |
| `spec/generation-checks/review-heap-reversed-round2.log` | This log records the R4 acceptance or rejection of a reviewer order fixture. |
| `spec/generation-checks/review-heap-reversed-round2.ndjson` | This v3 fixture preserves the reviewer's schedule and old fields while adding P2-callbacks capture fields. |
| `spec/generation-checks/run_checks.py` | The runner adds separate suffixes and parser, review-wrapper and timer-probe modes while preserving the resource limits. |
| `spec/generation-checks/sany-MC-round2.log` | This log records successful SANY parsing and semantic analysis for R3. |
| `spec/generation-checks/sany-Trace-round2.log` | This log records successful SANY parsing and semantic analysis for R3. |
| `spec/generation-checks/sany-base-initial-round2.log` | This superseded log preserves the initial token-spacing diagnostic before the successful final parse. |
| `spec/generation-checks/sany-base-round2.log` | This log records successful SANY parsing and semantic analysis for R3. |
| `spec/generation-checks/source-identity-round2.txt` | This record verifies that the source locations used to check both fixes and the candidates match the pinned Git blobs. |
| `spec/generation-checks/timer-runner-round2.log` | This log records sequential focused replay and checks each expected order or ownership result. |
| `spec/generation-checks/trace-corrupted-round2.log` | This log records R6 replay with both corrections loaded. |
| `spec/generation-checks/trace-valid-round2.log` | This log records R6 replay with both corrections loaded. |
| `spec/generation-checks/valid-round2.ndjson` | This fixture preserves the round-1 R6 schedule and old fields with the required v3 callback fields. |
| `spec/generation-manifest.json` | The manifest records the source and input identities, outcomes, changed-file inventory and artifact hashes for this round. |
| `spec/instrumentation-spec.md` | The mapping documents original-deadline heap order and the callback batch, execution context and pending-vector captures. |

## Criterion table

PASS means that the requested criterion was performed and evidenced. R5 retains the candidate violations and incomplete searches above. Kernel instrumentation, implementation traces, guest execution, Linux controls and runtime confirmation remain NOT RUN.

| Criterion | Status | Command from workspace root | Evidence |
|---|---|---|---|
| R1-heap | PASS | `python3 spec/generation-checks/audit_suite.py --manifest` | [audit-round2.log](generation-checks/audit-round2.log), [review-heap-reversed-round2.log](generation-checks/review-heap-reversed-round2.log), [probe-equal-deadlines-round2.log](generation-checks/probe-equal-deadlines-round2.log) |
| R2-callbacks | PASS | `python3 spec/generation-checks/run_checks.py timer --suffix=-round2` | [timer-runner-round2.log](generation-checks/timer-runner-round2.log), [review-callbacks-reversed-round2.log](generation-checks/review-callbacks-reversed-round2.log), [audit-round2.log](generation-checks/audit-round2.log) |
| R3-parse | PASS | `python3 spec/generation-checks/run_checks.py parse --suffix=-round2` | [sany-base-round2.log](generation-checks/sany-base-round2.log), [sany-MC-round2.log](generation-checks/sany-MC-round2.log), [sany-Trace-round2.log](generation-checks/sany-Trace-round2.log) |
| R4-review-fixtures | PASS | `python3 spec/generation-checks/run_checks.py review --suffix=-round2` | [review-control-round2.log](generation-checks/review-control-round2.log), [review-heap-reversed-round2.log](generation-checks/review-heap-reversed-round2.log), [review-callbacks-reversed-round2.log](generation-checks/review-callbacks-reversed-round2.log), [replay-evidence-round2.json](generation-checks/replay-evidence-round2.json) |
| R5-mc | PASS | `python3 spec/generation-checks/run_checks.py mc --suffix=-round2` | [mc-runner-round2.log](generation-checks/mc-runner-round2.log), [results-round2.json](generation-checks/results-round2.json) |
| R6-trace | PASS | `python3 spec/generation-checks/run_checks.py trace --suffix=-round2` | [trace-valid-round2.log](generation-checks/trace-valid-round2.log), [trace-corrupted-round2.log](generation-checks/trace-corrupted-round2.log), [replay-evidence-round2.json](generation-checks/replay-evidence-round2.json) |
| R7-records | PASS | `python3 spec/generation-checks/audit_suite.py --manifest` | [audit-round2.log](generation-checks/audit-round2.log) |
