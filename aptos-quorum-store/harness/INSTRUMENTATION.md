# Instrumentation Guide — Aptos Quorum Store Trace Harness

A short reference for the Phase 3 (validation) agent that needs to adjust the
instrumentation when trace validation reveals mismatches.

## Layout

```
harness/
  apply.sh                       -- applies instrumentation.patch to artifact
  run.sh                         -- end-to-end: apply + build + test + report
  patches/instrumentation.patch  -- git patch (generated from working tree)
  src/
    tla_trace.rs                 -- trace emission module (mirror copy)
    tla_trace_scenario_test.rs   -- test scenarios (mirror copy)
  INSTRUMENTATION.md             -- this file

traces/
  full_pipeline.ndjson           -- main scenario; covers most actions
  crash_recover.ndjson           -- Crash + Recover
  epoch_transition.ndjson        -- EpochTransition
  fetch_batch.ndjson             -- FetchBatchSuccess + supporting context
```

The two `src/` files are mirror copies of files that live inside the artifact
tree after `apply.sh` runs:

| Harness path                          | Artifact path |
|---------------------------------------|---------------|
| `src/tla_trace.rs`                    | `consensus/src/quorum_store/tla_trace.rs` |
| `src/tla_trace_scenario_test.rs`      | `consensus/src/quorum_store/tests/tla_trace_scenario_test.rs` |

If you modify the artifact copies, regenerate the patch with:

```sh
cd artifact/aptos-core
git add consensus/src/quorum_store/tla_trace.rs \
        consensus/src/quorum_store/tests/tla_trace_scenario_test.rs
git diff HEAD -- consensus/src/quorum_store/ \
  > ../../.specula-output/harness/patches/instrumentation.patch
git reset HEAD consensus/src/quorum_store/tla_trace.rs \
                consensus/src/quorum_store/tests/tla_trace_scenario_test.rs
```

## Instrumentation Map

| Event                       | Where (artifact-relative)                                       | Driver |
|----------------------------|-----------------------------------------------------------------|--------|
| `ReserveBatchId`            | `batch_generator.rs::create_new_batch`, after `Batch::new_*` (capture pre-increment `batch_id.id` and post-increment `self.batch_id.id`) | Production (full daemon) **and** harness (`scenario_full_pipeline` bypasses `create_new_batch` so it emits the same event explicitly) |
| `PersistPayload`            | `batch_generator.rs::start` loop, after `batch_writer.persist`  | Production. Harness emits it explicitly because tests bypass the `start` loop |
| `BroadcastBatchMsg`         | `batch_generator.rs::start` loop, after `broadcast_batch_msg{,_v2}` | Same caveat as `PersistPayload` |
| `HandleBatchesMsg`          | `batch_coordinator.rs::persist_and_send_digests`, after `batch_store.persist` | Production. Harness emits it explicitly per validator |
| `ReceiveSignedBatchInfo`    | `proof_coordinator.rs::add_signature`, after `value.add_signature` | Production (driven via `ProofCoordinator::start` channel in scenario) |
| `AggregateProof`            | `proof_coordinator.rs::add_signature`, after `aggregate_and_verify` returns Ok | Production |
| `HandleProofMsg`            | `batch_proof_queue.rs::insert_proof`, at function entry         | Production |
| `AdvanceCertifiedTime`      | `batch_store.rs::update_certified_timestamp`, after `fetch_max` (only when value advanced) | Production |
| `Recover`                   | Not auto-emitted; the harness emits it post-reconstruction in `scenario_crash_recover` because `BatchStore::new` is also used for fresh bootstrap (= Init in the spec) | Harness |
| `EpochTransition`           | Same caveat as `Recover`; emitted by `scenario_epoch_transition` | Harness |
| `BuildProposal`             | `proof_manager.rs::handle_proposal_request`, just before `callback.send` | Production |
| `CommitProposal`            | Not in production; emitted by harness                            | Harness (`emit_commit_proposal`) — `handle_commit_notification` has no proposer info |
| `Crash`                     | Not in production; emitted by harness before `drop(store)`       | Harness |
| `FetchBatchSuccess`         | `batch_requester.rs::request_batch`, before returning `Ok(payload)` (both V1+V2 arms) | Production. Harness `scenario_fetch_batch` emits it explicitly because driving the full requester loop in a unit test is unnecessarily heavy |

The `tla_trace::emit_*` helpers in `tla_trace.rs` are the only API surface;
they wrap the NDJSON envelope, validator ID translation, digest aliasing, and
the file writer.

## Validator ID / Digest mapping

The TLA+ spec is parameterized over `Validator = {"v1", "v2", "v3", "v4"}` and
`Digest = {"d1", "d2"}`. Real Aptos `PeerId`s and `HashValue` digests don't
match those symbolic names, so the harness builds a translation table at the
start of each scenario:

```rust
tla_trace::register_validator(signer.author(), "v1");
tla_trace::register_digest(batch.batch_info().digest().clone(), "d1");
```

Any subsequent `emit_*` call that needs to print a peer or digest looks up the
mapping first (fallback: `PeerId::short_str()` / `HashValue::to_hex()`).

## Trace.cfg overrides specific to trace replay

`spec/Trace.cfg` includes one override that is NOT in the model-checking cfgs
(`base.cfg`, `MC.cfg`):

```
CONSTANT Nil <- NilRecord
```

`NilRecord` is defined in `Trace.tla`. The vanilla `Nil = "Nil"` (string) makes
TLC unable to fingerprint a state where `inFlightOwnBatch` alternates between
record-typed BatchInfo and the bare string. Replacing Nil with a record-shaped
sentinel (out-of-range field values: `"_nilAuthor"`, `batchId=0`, etc.) keeps
the same `inFlightOwnBatch[v] = Nil` / `/= Nil` semantics while letting the
function value fingerprint cleanly. If you find a similar fingerprint failure
on `queueCanonical`, the fix is the same — it already shares the override.

## Common Adjustments

### Add a new field to an existing event

1. Edit the `emit_<event>` helper in `tla_trace.rs` — add the field to the
   `state` or `msg` JSON literal.
2. Update the call sites if the new field needs a value that is not already
   passed in.
3. Update `Trace.tla`'s `ValidatePost<Event>` clause to consume the new field
   (otherwise it is silently ignored by validation).

### Add a new event type

1. Add an `emit_<NewEvent>(...)` helper to `tla_trace.rs`, following the
   pattern of `emit_handle_batches_msg`. The envelope `tag: "trace"` is set
   inside `emit()`, so you do not need to repeat it.
2. Call the helper from the relevant production code path.
3. Add a `<NewEvent>IfLogged` action in `Trace.tla` and include it in
   `TraceNext`.

### Move a capture point (before → after)

The trigger time matters: most actions emit AFTER the state mutation completes
so the trace's `state` snapshot reflects the post-condition. Moving emission
to BEFORE the mutation requires a corresponding change in `Trace.tla`
(validate the pre-state instead of the post-state).

The two exceptions in this harness:

- `BuildProposal` — captured between proof_block assembly and `callback.send`
  so the post-state of `proposalsBuilt` is observable before the response
  races back to consensus.
- `AdvanceCertifiedTime` — only emitted when `fetch_max` actually advanced the
  atomic; this matches the spec's `t > localCertifiedTime[v]` precondition.

### Add a new test scenario

1. Add a `#[tokio::test(flavor = "multi_thread")] async fn scenario_<name>` in
   `tla_trace_scenario_test.rs`.
2. Call `init_trace("<name>", &signers)` at the top — opens a fresh trace
   file at `${APTOS_QS_TLA_TRACE_DIR}/<name>.ndjson`, registers the validator
   ID mapping, and emits the config line.
3. Drive the production code; events fire automatically from the instrumented
   call sites.
4. For events whose production path is too heavyweight to set up
   (e.g. `BroadcastBatchMsg`, `PersistPayload` — both live inside
   `BatchGenerator::start`'s `tokio::select!` loop), call the matching
   `tla_trace::emit_*` helper directly from the test.
5. Adapt spec constant bounds (`MaxBatchId=3`, `MaxEpoch=2`, `MaxTimeTick=6`,
   `Digest={"d1","d2"}`) — scenario fields must lie inside these ranges or
   the trace will not type-check.

## Rebuilding & re-running

After any change, the canonical command is:

```sh
cd .specula-output
bash harness/run.sh
```

This regenerates traces in `traces/*.ndjson` and prints per-file event counts.
Validate the traces with:

```sh
# From the validation skill / TLC harness:
run_trace_validation \
  spec_file=Trace.tla \
  config_file=Trace.cfg \
  trace_file=../traces/full_pipeline.ndjson \
  work_dir=spec/
```

The current end-of-run output looks like:

```
running 4 tests
test quorum_store::tests::tla_trace_scenario_test::scenario_crash_recover ... ok
test quorum_store::tests::tla_trace_scenario_test::scenario_epoch_transition ... ok
test quorum_store::tests::tla_trace_scenario_test::scenario_fetch_batch ... ok
test quorum_store::tests::tla_trace_scenario_test::scenario_full_pipeline ... ok

test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured

[run.sh] trace files:
  crash_recover.ndjson      3 lines
  epoch_transition.ndjson   2 lines
  fetch_batch.ndjson        6 lines
  full_pipeline.ndjson      21 lines
```

A successful TLC trace-replay run finishes with `Error: Deadlock reached.` —
that's not a real error: the trace is fully consumed (`l > Len(TraceLog)`)
and there is no successor state.  Look for invariant violations or
counterexamples in the output; their absence (as in the current state) means
validation passed.

If validation fails, the error message points to a specific cursor position
`l = <N>`. Open `traces/<scenario>.ndjson`, count to that 1-indexed line
(skip the leading `config` line), and check whether the emitted
`state.<field>` agrees with the spec's post-state. Usual fixes:

- The emit helper passes the wrong value (e.g. reads `self.batch_id` AFTER
  increment when the spec wants the pre-increment value). Adjust the call
  site to capture the value at the right time.
- The validator name or digest map is missing an entry — the trace's `nid`
  or `digest` falls back to a hex string and `Trace.cfg`'s `Validator` /
  `Digest` set rejects it. Make sure `register_validator` and
  `register_digest` were called for every signer / batch.
- The trace event fires from a code path the spec does not model. Either
  guard the emit with a condition, or add a `Silent...` clause in
  `Trace.tla` to absorb it.

## Caveats

- The trace module uses a process-wide `Lazy<Mutex<TraceState>>`. Tests must
  run with `--test-threads=1` (which `run.sh` does) so the global trace file
  is not torn down mid-scenario.
- `APTOS_QS_TLA_TRACE_DIR` selects the output directory; per-scenario file
  names are hard-coded inside each test. If you rename a scenario, update the
  call to `init_trace("<new-name>", ...)`.
- The Aptos workspace has `unwrap_used = "deny"` for the consensus crate. All
  trace code uses `.expect()` or pattern matching; do not introduce
  `.unwrap()` in `tla_trace.rs` or you will break lint.
- `Recover` and `EpochTransition` are NOT emitted from inside `BatchStore::new`
  because the same constructor is also used for the validator's initial
  bootstrap (which the spec models as `Init`, not as a transition). If you
  add a new scenario that exercises a real crash-recover boundary, emit
  `tla_trace::emit_crash(peer)` before dropping the store and
  `tla_trace::emit_recover(peer)` after reconstructing it.
