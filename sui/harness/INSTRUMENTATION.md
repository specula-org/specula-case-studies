# Sui Mysticeti Trace Harness — Instrumentation Guide

This document is the on-ramp for the Phase 3 validation agent. It explains
where instrumentation lives, how scenarios drive trace generation, and how
to adjust either when validation surfaces issues.

## Files

| Path | Purpose |
|------|---------|
| `harness/src/tla_trace.rs` | Trace emission module. Copied into `artifact/sui/consensus/core/src/tla_trace.rs` by `apply.sh`. |
| `harness/src/tla_trace_scenarios.rs` | Test scenarios that drive the real `BaseCommitter` / `Linearizer` / `DagState`. Copied into `artifact/sui/consensus/core/src/tests/tla_trace_scenarios.rs`. |
| `harness/apply.sh` | Idempotently copies the two files into the artifact and patches `lib.rs`. |
| `harness/run.sh` | One-command pipeline: apply → build tests → run each scenario in its own process → preprocess. |
| `harness/preprocess_trace.py` | Compresses real digests/timestamps to small spec integers (`1..MaxDigest`, `0..MaxTimestamp`). |
| `traces/<scenario>.ndjson` | Raw trace with u64 digests + ms timestamps. |
| `traces/<scenario>.preprocessed.ndjson` | Spec-domain trace (digest ∈ 1..MaxDigest, timestamp ∈ 0..MaxTimestamp). Feed this to TLC. |

## Activation model

`tla_trace::writer()` reads the `TLA_TRACE_FILE` env var on first call.
Without it, every `emit_*` is a no-op. Each scenario runs in its own
`cargo test` process so the static writer starts clean and the env var
points to a distinct file. **Do not run multiple scenarios in the same
process** — the writer is initialized once per process.

## Server ID mapping

`AuthorityIndex(i)` → `"s{i+1}"` in the trace. `Trace.cfg` declares
`Server = {"s1", "s2", "s3", "s4"}` — strings, not model values.
If you regenerate `Trace.cfg`, keep the strings (model values
would not equal the JSON strings emitted by the harness).

## Event coverage

| Event | Emitted by | Scenarios with this event |
|-------|------------|---------------------------|
| `HonestPropose` | `emit_propose(force=false, ...)` from scenarios | normal, equivocation, force_propose, crash_recover |
| `ForcePropose` | `emit_propose(force=true, ...)` | force_propose |
| `ByzPropose` | `emit_byz_propose` | equivocation |
| `DeliverBlock` | `emit_deliver_block` after `dag_state.accept_block` | all |
| `TryDirectDecide` | `emit_try_direct_decide` after `BaseCommitter::try_direct_decide` | all |
| `TryIndirectDecide` | `emit_try_indirect_decide` — **emit function exists but no scenario triggers it yet**. To exercise it, build a scenario where direct decide is `Undecided` for some leader, then `Linearize` a later leader, then re-call decide on the earlier slot. | none |
| `Linearize` | `emit_linearize` after `Linearizer::handle_commit` | normal, force_propose, crash_recover (not equivocation — slot s4@3 stays Undecided in that scenario) |
| `Crash` | `emit_crash` from scenario before manually wiping DagState | crash_recover |
| `RecoverAmnesia` | `emit_recover_amnesia` from scenario after re-creating DagState | crash_recover |
| `AddCertifiedCommit` | `emit_add_certified_commit` — **emit function exists but no scenario triggers it yet**. To exercise it, set up a `CoreTestFixture` (see `core.rs:949`) and feed `Core::add_certified_commits`. | none |

The two uncovered events have full `emit_*` functions ready in
`tla_trace.rs`. Phase 3 can add scenarios that exercise them.

## How scenarios drive the real protocol

Each scenario in `tla_trace_scenarios.rs` constructs 4 `ValidatorHarness`
instances. Each harness has its own real `Context`, `DagState`,
`BaseCommitter`, and `Linearizer` (all `#[cfg(test)]` paths in the
production code). The scenario:

1. Builds blocks via `TestBlock::new(round, author).set_ancestors(...).build()`.
2. Accepts them into each validator's `DagState` via real `accept_block`.
3. Runs the real `committer.try_direct_decide(slot)` per leader slot.
4. Runs the real `linearizer.handle_commit(leader_blocks)` for committed leaders.

The harness emits an event around each real call — no protocol logic is
reimplemented in the harness.

### Phasing rule (important)

`one_round_all_authors` and `one_round_subset` proceed in two phases:

* **Phase 1**: Every author produces its round-r block locally
  (`dag_state.write().accept_block`) and the harness emits the
  `HonestPropose`/`ForcePropose`. At this point each validator's
  `clockRound` is still `r` (own-block is not quorum).
* **Phase 2**: Every block is cross-delivered. `clockRound` advances
  to `r+1` only after a quorum at round r is in dag.

If you merge the phases (interleave per-author accept-then-deliver),
late authors' `clockRound` will advance past `r` before they propose,
and the spec rejects their `HonestPropose` (`r == clockRound[s]` fails).

## Trace cfg files

| Config | Use for | Byzantine |
|--------|---------|-----------|
| `spec/Trace.cfg` | normal, force_propose, crash_recover | `{}` (no Byzantine) |
| `spec/TraceByz.cfg` | equivocation | `{"s4"}` |

The equivocation scenario emits `ByzPropose` events for s4 (which
require `s4 ∈ Byzantine`) and `HonestPropose` for s1..s3. Other
scenarios contain only `HonestPropose`, so the default cfg's
`Byzantine = {}` is correct.

## Adjusting instrumentation for Phase 3

### Adding a new field to an existing event

1. Open `harness/src/tla_trace.rs`.
2. Edit the relevant `emit_*` function signature to accept the field.
3. Update its `format!(r#"…"#)` to include the field.
4. Update every caller in `harness/src/tla_trace_scenarios.rs`.
5. Run `apply.sh` then `cargo check -p consensus-core --tests`.

### Adding a new event type

1. Add a new `emit_<name>` function in `tla_trace.rs` following the existing pattern.
2. Add a call site in `tla_trace_scenarios.rs` — must be wrapped around a real production call, not a simulator step.
3. Add an `<Name>IfLogged` wrapper in `spec/Trace.tla` and a disjunct in `TraceNext`.
4. Add validators (`ValidatePostState…`) if the event has post-state fields.

### Moving a capture point (before → after or vice versa)

Each `emit_*` is called *after* the real action returns. To capture
pre-state instead, snapshot the DAG read before the call:

```rust
let (cr_before, gc_before) = clock_gc(&validators[a].dag_state);
let outcome = validators[a].committer.try_direct_decide(slot);
let (cr_after, gc_after) = clock_gc(&validators[a].dag_state);
tla_trace::emit_try_direct_decide(..., outcome, /* pass before or after */);
```

Match whichever the spec validator (`ValidatePostState…` in `Trace.tla`)
expects. The current setup captures post-state.

### Adding a scenario

1. Add a `#[tokio::test] async fn tla_trace_scenario_<name>()` in `tla_trace_scenarios.rs`.
2. Add the name to the `SCENARIOS` array in `run.sh`.
3. Re-run `bash run.sh`.

### Rebuilding after changes

```
bash .specula-output/harness/apply.sh                     # copy files
cd artifact/sui && cargo check -p consensus-core --tests   # surface compile errors
bash .specula-output/harness/run.sh                       # rebuild + run all scenarios
```

## Preprocessor

`preprocess_trace.py` compresses two domains:

* **Digests** — per `(author, round)` slot, the *k*-th distinct u64
  digest seen becomes spec digest `min(k, MaxDigest)`. With
  `MaxDigest = 2`, this models honest blocks (digest 1) and a single
  equivocation (digest 2). All ancestor refs and `commitVotes` are
  remapped consistently.
* **Timestamps** — sorted globally, assigned ranks `1..MaxTimestamp`
  preserving order. Genesis `timestamp=0` stays 0.

If `Trace.cfg`'s `MaxDigest` or `MaxTimestamp` change, edit the
constants at the top of `preprocess_trace.py` to match.

## Known issues for Phase 3

1. **TLC `Nil = record` runtime check in `base.tla::IsVote`.**
   `FindSupportedBlock` returns `Nil` when no ancestor matches the
   leader slot. `IsVote` then evaluates `Nil = RefOf(leaderBlock)`,
   which TLC rejects (record vs string equality). Fix in the spec:

   ```tla
   IsVote(s, voter, leaderBlock) ==
       LET found == FindSupportedBlock(s, SlotOf(leaderBlock), voter)
       IN found /= Nil /\ found = RefOf(leaderBlock)
   ```

2. **`Cardinality(signedHistory[s])` carryover.** The harness's
   `record_signed` is a process-wide static — when scenarios run in
   the same process (they currently don't, but if Phase 3 changes
   that), `signedHistorySize` keeps growing across scenarios. Each
   `cargo test` invocation creates a new process, so this is OK in
   the current run.sh pipeline.

3. **`Byzantine = {}` is the default cfg.** Scenarios that don't
   produce `ByzPropose` events should use `Trace.cfg`. Scenarios that
   do (currently just `equivocation`) should use `TraceByz.cfg`.

4. **Round-3+ `Linearize` events in the crash_recover scenario.** The
   recovered validator's `decided` map is cleared, but its dag is
   replenished. When it commits leaders for rounds it wasn't online
   for, the linearizer recovers a sub-dag that may include blocks
   whose round-r predecessors are missing in dag[s] (because they
   were never re-delivered after recovery). Phase 3 may need to
   either re-deliver more pre-crash history or skip decide on the
   recovered validator for the pre-crash rounds.

## Files modified in the artifact

`apply.sh` writes these (idempotent):

```
artifact/sui/consensus/core/src/tla_trace.rs                 (new)
artifact/sui/consensus/core/src/tests/tla_trace_scenarios.rs (new)
artifact/sui/consensus/core/src/lib.rs                       (appended)
```

To revert, run:

```
cd artifact/sui && git checkout -- consensus/core/src/lib.rs
rm consensus/core/src/tla_trace.rs consensus/core/src/tests/tla_trace_scenarios.rs
```
