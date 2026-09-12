# Adjusting the History queue harness

Run from `.specula-output` with `bash harness/run.sh`. It applies the pinned-source patch, compiles/runs six Go test schedules, projects measured NDJSON, replays every trace with TLC, and tests eight corruptions. `TEMPORAL_SOURCE` selects another checkout of the exact pinned revision. Java and Go are required; TLC and CommunityModules jars are bundled in `tools/`.

## Files and capture points

- `src/trace.go`: mutex-protected NDJSON writer, real UTC timestamps, hook callbacks, and observation providers.
- `src/queue_probe.go`: controlled scheduling adapter around the actual queue, readers, executor wrappers and rescheduler; direct private-state sampling.
- `src/queue_hooks.go`: reader ordering for the controlled schedule; full slice/tracker/predicate snapshots, including staged and detached objects.
- `src/shard_probe.go`: allocator/tracker/context sampling and the test entry into real fresh acquisition.
- `src/scenarios_test.go`: existing Transfer executor test infrastructure, SQLite stores, real workflow mutations, fault schedules, independent readback, and Matching store-boundary adapter.
- `patches/instrumentation.patch`: emit sites in real production methods. See [POINTS.md](POINTS.md) for exact applied file/line locations.
- `reduce.py`: observation projection and historical hook receipts. It must not synthesize missing rows, scopes, accepted effects, or task completion. Unused identity slots describe absent objects; control PCs describe measured hook locations.
- `validate.py`: full replay, L2 check, event coverage, and negative controls. Negative files are labelled `synthetic-spec-test` and stay under evidence, never in implementation `traces/`.

## Small adjustments

To add a field, read it in the relevant queue/shard/store probe, retain its raw provenance, project it in `reduce.py`, and extend the mandatory `DecodeState`/base state when appropriate. Every field in `post` is checked by full equality. Raw protobufs and page/call diagnostics stay in the sidecar; they are evidence, not extra unchecked model state.

To add an event, insert a guarded emit at the real source boundary, add its observation projection, and add a Go schedule. Keep commits separate from caller replies and snapshot capture separate from store I/O. Use raw backend readback for effects. Preserve unknown-event rejection and final Endpoint checks.

To move a capture before/after a mutation, move the production emit. Re-run and inspect the first failed TLC event; do not reorder trace lines or fill missing state from model output. Probes execute on the serialized schedule and may already hold a reader/shard lock. They intentionally avoid recursively acquiring that same lock. This configuration is not suitable for uncontrolled service goroutines.

Edit helper/test sources in `harness/src/`, then rerun. For production hook edits, edit the applied target file, regenerate the patch using only the recorded instrumentation files, and rerun. Keep the pre-existing investigation tests intact. `apply.sh` is idempotent and refuses conflicting tracked changes. `clean.sh` reverses only this patch and removes only installed files whose hashes still match; it never resets the checkout.

[REPORT.md](REPORT.md) records observation boundaries, backend/configuration, adapter corrections, and all uncovered actions. Latest commands/logs, independent SQLite files, raw sidecars, replay verdicts, and hashes are located by `evidence/latest-run.txt`.

Validation extensions: `cursor_healthy` and `cursor_stall` preserve real executor eligibility, Matching SQL acceptance, full cursor snapshots, durable reader1 scopes, and fresh-acquisition recovery. `selected_slice` records the just-loaded object even when the reader cursor has advanced to nil. Supplemental `validation_tracker_test.go` and `validation_checkpoint_test.go` probe CR-2 duplicate accounting and CR-3 semaphore cancellation independently of trace replay.
