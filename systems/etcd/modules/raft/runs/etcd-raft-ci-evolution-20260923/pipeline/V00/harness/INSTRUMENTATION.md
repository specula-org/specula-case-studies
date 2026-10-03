# V00 trace harness maintenance

Run from `.specula-output/`:

```sh
bash harness/run.sh
python3 harness/validate.py
bash harness/test.sh
# Complete positive/negative checks and regenerate the hash-bound report:
bash harness/verify.sh
```

`run.sh` applies the observational patch, builds, runs five Go scenarios, checks every NDJSON record, audits event/branch coverage, and reports counts. Logs and previous batches are retained under `harness/logs/`. `test.sh` runs the supplied upstream tests and all harness tests with Go's race detector; its extra traces have a separate directory. Dependencies, build caches, durability images and temporary files stay under the run's `tmp/`.

The canonical editable sources are in `harness/src/`. `apply.sh` copies them into the checkout and applies `patches/instrumentation.patch` idempotently. It refuses conflicting changes and never resets the tree. `clean.sh` checks that copied files have no unpreserved edits, reverses only this patch, and removes only its copied files. Preserve a Phase 3 edit in `harness/src/` before reapplying. The source's preexisting `.codex/` directory is untouched.

## Capture points after apply

All paths in this table are relative to `source/`. Line numbers refer to this delivered instrumentation.

| Location | Observation |
|---|---|
| `raft.go:431` | Actual message at `send`, after From/Term normalization; attaches send-time log/read provenance. |
| `raft.go:567,616,1064` | Progress reset, self append and successful remote Match update. Remote evidence comes from the exact delivered wire instance. |
| `raft.go:973,977,996,999,1212,1250,1254,1258` | Actual proposal admission/drop/forward branch. No observer reimplements the decision guard. |
| `raft.go:1019,1030,1123,1125` | Read initiation/self ACK, singleton release, quorum confirmation and the actual released prefix. |
| `raft.go:1407` | Completed full snapshot restore/configuration origin. Fast restore is observed in the enclosing Receive post-state. |
| `node.go:354` | Node loop boundary after housekeeping and before the next select; observes previous HS/SS, leader cache and proposal-channel enable state. |
| `tracker/specula_inflights.go:8` | Copies the logical ring order under the caller's Raft boundary. |
| `specula_values_test.go:229,279,315,376` | Mutex writer, message projection, full core snapshot, and source-hook dispatch. |
| `specula_caller_test.go:284,293,381,454` | Serialized public calls; outer core events, API outcomes and immutable actual Ready capture. |
| `specula_caller_test.go:517,549,570,587` | Logical write start, fsync/rename completion, real MemoryStorage visibility calls and individual message publication. |
| `specula_caller_test.go:599,607,652,818` | Ordered application queue, actual Advance, application/ApplyConfChange and durable application checkpoint. |
| `specula_caller_test.go:825,837,853,869,879,907,937` | Client completions, snapshot creation/compaction, transport reports, crash/Stop and durable-file recovery. |

The hooks compile to no-ops without `-tags specula`. In the tagged harness, the Node goroutine parks at its boundary while the scheduler observes all nodes or performs caller work. Resume/arrival channels synchronize each public call. RawNode calls are serialized directly. This gives coherent full observations; no weak field capture or silent model actions are used. It samples legal sequential schedules of concurrent interfaces, rather than all possible channel/storage interleavings.

## Small adjustments

To add a core field, read it in `sxNode.capture` in `specula_values_test.go`; for a caller field, change `diskValue`, `appValue`, or the immutable batch capture in `specula_caller_test.go`. Add its counterpart to the reference record. `ValidatePostState` compares the entire typed value, so a captured field without a reference counterpart fails instead of becoming dead data.

To add an event, add the public-interface scheduler method, emit once after its actual completion, and add the base action/Trace wrapper/parameter schema. Internal helpers remain part of the enclosing core event. Source hooks attach otherwise unavailable provenance; they do not split Step into fictitious network-visible actions. Add a scenario or document the unvisited branch in `CORRESPONDENCE.md`.

To move a capture point, move the hook relative to the source mutation and regenerate the patch from a clean copy of the supplied revision. `patches/build-patch.py` documents the exact anchor placements; it is a developer utility, not part of apply/run. Move the matching caller emit only when the observed public operation's boundary actually changes. Never populate observations from TLA output.

Use `gofmt -w harness/src/*.go harness/src/tracker/*.go`, then rerun `run.sh`, `audit.py`, and `validate.py`. `debug.py` invokes the pinned trace debugger with JSON breakpoint arguments; use `TLCGet("level")` conditions. Both drivers replace only launch settings that the MCP schema cannot configure: explicit heap/direct memory/workers and run-local paths. They refuse an unaccounted concurrent TLC instance. Each validation instance uses 8 GiB heap + 1 GiB direct and two workers; debugging uses one worker. `validate.py --parallel` permits at most six isolated instances (54 GiB / 12 workers total) after refusing any preexisting TLC process. Each parallel case has a separate run-local work directory and state directory. All logs and TLC states are retained.

## Negative checks

After positive replay succeeds:

```sh
python3 harness/negative_traces.py
python3 harness/validate.py harness/negative-traces/*.ndjson
python3 harness/prepare_oracle.py
python3 harness/validate.py --oracle
python3 harness/validate.py --oracle harness/negative-traces/*.ndjson
```

The negative validation commands intentionally return nonzero for rejection. Mutants are copies of real prefixes and are never executed against Raft. The manifest records each mutation and source hash. `OracleTrace.tla` is a separately labeled observation-only sensitivity check using the unchanged base predicates; it does not replace full action correspondence or the canonical invariant list. A missing completed persistence entry is checked by correspondence and is not claimed to trigger one of the six supplementary observational predicates.
