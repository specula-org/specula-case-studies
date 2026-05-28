# HotShot Trace-Harness Instrumentation

Reference for the Phase 3 (Spec Validation) agent.

## Overview

This harness instruments the **EspressoSystems/espresso-network** Rust artifact
(`crates/hotshot/`) to emit NDJSON traces of consensus actions. The traces are
consumed by `Trace.tla` (single linear cursor `l`).

Layout:

```
harness/
├── src/
│   ├── tla_trace.rs           # Trace emission library (thread-safe NDJSON writer)
│   └── trace_harness_test.rs  # Test scenarios that drive consensus tasks
├── apply.sh                   # Idempotent patcher (copies files + edits source)
└── run.sh                     # End-to-end: apply, build, test, collect, summarize

traces/
├── crash_recover.ndjson
├── handle_quorum_proposal_recv.ndjson
└── propose_leader.ndjson
```

## Critical Spec Fix Applied

`Trace.cfg` originally declared `Server = {s1, s2, s3}` (TLC model values), but
JSON-deserialized `nid` fields are TLA+ strings, so the assumption
`TraceServer \subseteq AllReplicas` failed. Apply.sh does NOT modify the spec —
we fixed `Trace.cfg` once:

```diff
- Server          = {s1, s2, s3}
+ Server          = {"s1", "s2", "s3"}
```

`TraceSpec` in `Trace.tla` also needed a fairness constraint to make
`TraceMatched == <>(l > Len(TraceLog))` non-trivially satisfiable. Added
`SF_<<vars, traceVars>>(TraceNext)` to the spec.

## Currently Instrumented Events

The first pass instruments four spec actions in real Rust source:

| Event | Source location | What's captured |
|-------|-----------------|-----------------|
| `HandleQuorumProposalRecv` | `quorum_proposal_recv/handlers.rs::handle_quorum_proposal_recv` (after final `broadcast_view_change` on the success path) | view, leaf, parentLeaf, epochClaim, evidenceKind + full state snapshot |
| `ProposeLeader` | `quorum_proposal/handlers.rs::publish_proposal` (after `QuorumProposalSend` broadcast) | view, leaf, evidenceKind + state snapshot |
| `Crash` | harness-only (emitted from `trace_harness_test.rs`) | nid only |
| `Recover` | harness-only (emitted from `trace_harness_test.rs`) | nid only |

The trace module (`crate::tla_trace`) is added to
`crates/hotshot/task-impls/src/`. It writes NDJSON lines with envelope:

```json
{"tag":"trace","ts":"<epoch_ns>",
 "event":{"name":"<ActionName>","nid":"s1","view":1,"epoch":0,
          "state":{"crashed":false,"curView":1,"curEpoch":0,"lockedView":0,
                   "latestVotedView":0,"highestBlock":0,
                   "highQcInMemView":0,"highQcPersistedView":0},
          "msg":{...}}}
```

Output file path is taken from the `TLA_TRACE_FILE` env var (or set via
`tla_trace::set_path(&path)`). Disabled if the file can't be opened.

## Not Yet Instrumented (Phase 3 Extensions)

These events from the instrumentation spec are NOT currently emitted. The
harness is structured so they can be added with the same pattern.

| Event | Where to instrument | Why deferred |
|-------|---------------------|--------------|
| `SubmitVote` | `quorum_vote/handlers.rs::submit_vote` after `QuorumVoteSend` broadcast | Needs the node id passed in (requires adding an `id: u64` parameter to `submit_vote` and changing the caller at `quorum_vote/mod.rs:409`). See § "Extending Instrumentation" below. |
| `TimeoutVote` | `consensus/handlers.rs::handle_timeout` after `TimeoutVoteSend` broadcast | `task_state.id` and `task_state.consensus` are in scope. Pattern parallels HandleQuorumProposalRecv. The `digest_hex` field for Family-A bug hunting can be added here. |
| `FormQC` / `FormTC` / `FormViewSyncCert` | `vote_collection.rs::accumulate_vote` at the threshold-met branch | The generic `CERT` parameter erases the cert type at runtime. Use `std::any::type_name::<CERT>()` to dispatch between QC/TC/VSC, or split into separate handlers per type. |
| `ObserveQC` | `types/src/consensus.rs::update_high_qc` (start, before the L1327 early return) | `hotshot-types` cannot depend on `hotshot-task-impls` (would be circular). Either: (a) add a separate `tla_trace.rs` to `hotshot-types`, or (b) take a `node_id: u64` parameter on `update_high_qc` and emit from the caller side. Option (b) is more invasive (many callers). |
| `ViewSyncVote` | `view_sync.rs:702-706` (PreCommit→Commit), `:793-797` (Commit→Finalize), `:914-918` (initial PreCommit) | Three sites; `self.id` is in scope. Watch for the Family-C distinction: emit `certificate.data().relay`, NOT `self.relay`. |
| `CommitLeaf` | `consensus/handlers.rs` decide path (handler for `LeafDecided`) | Need to find the right hook — `LeafDecided` may be processed in `consensus/handlers.rs` or elsewhere. |

## Extending Instrumentation

To add a new emit point, follow the existing pattern in
`quorum_proposal_recv/handlers.rs`:

```rust
// TLA_TRACE_MARKER: <EventName>
{
    use crate::tla_trace;
    if tla_trace::is_enabled() {
        // Read state under existing locks (or wrap a fresh read).
        let cr = task_state.consensus.read().await;
        let cur_view = cr.cur_view().u64();
        let locked_view = cr.locked_view().u64();
        let high_qc_view = cr.high_qc().view_number().u64();
        let highest_block = cr.highest_block;          // Field, not method.
        drop(cr);

        let nid = tla_trace::nid(task_state.id);       // 0 → "s1", 1 → "s2", ...
        let state = tla_trace::state_obj(
            cur_view, /* curEpoch */ 0,
            locked_view, /* latestVotedView */ 0,
            highest_block, high_qc_view,
            /* highQcPersistedView */ high_qc_view,
            /* crashed */ false,
        );
        let msg = serde_json::json!({ "view": cur_view, /* ... */ });
        tla_trace::emit("EventName", &nid, cur_view, /* epoch */ 0, state, msg);
    }
}
```

Then add a marker check at the top of the patched block in `apply.sh`:

```bash
marker = "// TLA_TRACE_MARKER: EventName"
if marker in src:
    sys.exit(0)
```

so `apply.sh` is idempotent.

## State Capture Levels

The instrumentation spec calls for these fields in every event:

| Field | Source | Capture quality (today) |
|-------|--------|-------------------------|
| `state.curView` | `consensus.read().await.cur_view()` | **Full** (instrumented) |
| `state.curEpoch` | `consensus.read().await.cur_epoch()` | **Full** |
| `state.lockedView` | `consensus.read().await.locked_view()` | **Full** |
| `state.latestVotedView` | `quorum_vote_task.latest_voted_view` | **Missing** — set to 0. The QuorumVoteTaskState holds this, but it isn't reachable from the recv-task context. Trace.tla's `ValidateSubmitVote` requires it for SubmitVote events; we currently emit 0 which will fail that check until SubmitVote is instrumented. |
| `state.highestBlock` | `consensus.highest_block` | **Full** |
| `state.highQcInMemView` | `consensus.high_qc().view_number()` | **Full** |
| `state.highQcPersistedView` | requires explicit `storage.high_qc().await` read | **Shadow-only** — we emit the same value as in-mem. The Family-D MC4 finding requires distinguishing these; Phase 3 should add the storage shadow read. |
| `state.crashed` | derived from harness, not impl | **Full** |

## Compile-Time Notes

- `serde_json` was added to BOTH `crates/hotshot/task-impls/Cargo.toml` AND
  `crates/hotshot/testing/Cargo.toml` (the test scenario uses it for
  Crash/Recover emit). It is already in the workspace `[workspace.dependencies]`.
- `pub mod tla_trace;` is added to `crates/hotshot/task-impls/src/lib.rs`
  after `pub mod stats;`. The module file lives at
  `crates/hotshot/task-impls/src/tla_trace.rs`.
- The test scenario lives at
  `crates/hotshot/testing/tests/tests_1/trace_harness_test.rs`. The
  `tests_1.rs` file uses `automod::dir!`, so no explicit `mod` declaration
  is needed.
- All function signatures are unchanged in the current pass — none of the
  patches require adding parameters. Extending to `submit_vote` will require
  changing the signature; the apply.sh has a commented-out patch for that.

## Build & Run

Single command:

```
cd .specula-output && bash harness/run.sh
```

Steps:
1. `apply.sh` — copies `tla_trace.rs` into `crates/hotshot/task-impls/src/`,
   patches `lib.rs` and `Cargo.toml`, applies emit calls.
2. `cargo build -p hotshot-task-impls` — verifies patches compile.
3. `cargo test -p hotshot-testing --test tests_1 tla_trace -- --nocapture --test-threads=1`
   — runs the three trace tests sequentially with `TLA_TRACE_DIR` set.
4. Summarizes line counts and validates JSON.

To revert all patches:

```
bash harness/apply.sh --clean
```

## Running Trace Validation

```
cd spec/ && TLC_OPTS="-workers 1" \
  JSON=../traces/crash_recover.ndjson \
  java -DTLA-Library=.../CommunityModules-deps.jar \
       -cp .../tla2tools.jar:.../CommunityModules-deps.jar \
       tlc2.TLC -config Trace.cfg Trace.tla
```

or via the MCP tool:

```
run_trace_validation(
    spec_file="Trace.tla",
    config_file="Trace.cfg",
    trace_file="../traces/crash_recover.ndjson",
    work_dir=".specula-output/spec/",
)
```

## Validation Status

| Trace | Lines | TLC validation |
|-------|-------|----------------|
| `crash_recover.ndjson` | 2 | **PASSES** (`states_generated: 4`) |
| `handle_quorum_proposal_recv.ndjson` | 1 | **FAILS at line 1** — requires preceding `ProposeLeader` (see Known Issue 2) |
| `propose_leader.ndjson` | 0 | n/a — production code paths in `publish_proposal` were never reached because dependency graph was not satisfied (see Known Issue 1) |

## Known Issues

1. **`propose_leader.ndjson` is empty.** The `QuorumProposalTaskState`
   uses a dependency-handle pattern (`ProposalDependencyHandle`) that
   spawns the actual propose call on dependency-graph completion. Feeding
   events one-at-a-time to `task.handle()` does not properly satisfy the
   dependency graph (you'll see `ProposalDependency::PayloadAndMetadata
   for view ... dependency cancelled` in the test log). To trace
   `ProposeLeader`, Phase 3 should drive a full multi-node test instead
   of a single isolated task, e.g. by adapting an existing integration
   test like `test_success` (after instrumenting trace emission).

2. **`handle_quorum_proposal_recv.ndjson` fails trace validation at line
   1.** The spec's `HandleQuorumProposalRecv` requires the proposal to
   exist in the `proposals` bag (which is empty at `Init` and is only
   populated by `ProposeLeader`). Since the single-task test feeds a
   proposal directly without a preceding `ProposeLeader`, the spec
   action's precondition fails. Two fixes:
   - **Spec side**: Add a "silent" `BootstrapProposalIfLogged` wrapper
     that inserts the proposal into the bag without producing a trace
     event. This is a small addition to `Trace.tla`.
   - **Harness side**: Drive `ProposeLeader` first (which adds to the
     bag) and only then `HandleQuorumProposalRecv`. This requires a
     multi-task scenario; see Issue 1.

3. **The `Trace.cfg` `Server` constant was changed from model values to
   strings** (see "Critical Spec Fix Applied" above). This is necessary
   because Rust→JSON serializes node IDs as strings; trying to match a
   string `"s1"` against a TLC model value `s1` always fails. The fix
   is a one-line cfg edit; the spec itself works equivalently with
   strings (functions over `AllReplicas` use the keys uniformly).

4. **`TraceSpec` needs a fairness constraint** to make
   `TraceMatched == <>(l > Len(TraceLog))` non-trivially satisfiable.
   Without `SF_vars(TraceNext)`, TLC finds an infinite-stutter
   counterexample where `l` never advances. We added
   `SF_<<vars, traceVars>>(TraceNext)` to `TraceSpec` in `Trace.tla`.

## Quick Reference: File Manipulation by apply.sh

| File | Patch | Marker |
|------|-------|--------|
| `crates/hotshot/task-impls/src/tla_trace.rs` | created | `tla_trace.rs` exists |
| `crates/hotshot/task-impls/src/lib.rs` | add `pub mod tla_trace;` | `pub mod tla_trace;` |
| `crates/hotshot/task-impls/Cargo.toml` | add `serde_json` | `serde_json = { workspace = true }` |
| `crates/hotshot/testing/Cargo.toml` | add `serde_json` | `serde_json = { workspace = true }` |
| `crates/hotshot/task-impls/src/quorum_proposal_recv/handlers.rs` | insert emit | `// TLA_TRACE_MARKER: HandleQuorumProposalRecv` |
| `crates/hotshot/task-impls/src/quorum_proposal/handlers.rs` | insert emit | `// TLA_TRACE_MARKER: ProposeLeader` |
| `crates/hotshot/testing/tests/tests_1/trace_harness_test.rs` | created | file exists |

All edits are idempotent — re-running `apply.sh` is safe.
