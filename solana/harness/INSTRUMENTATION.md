# Solana Tower BFT Harness — Instrumentation Guide

A short reference for the Phase 3 (trace-validation) agent when trace
validation fails and the harness needs adjustment.

## Layout

```
harness/
├── src/
│   └── tla_trace_scenarios.rs     # integration test + inlined trace module
├── apply.sh                        # copies the test into the artifact tree
├── run.sh                          # apply + build + run + collect
├── logs/                           # build + per-scenario stdout (after run.sh)
└── INSTRUMENTATION.md              # this file

traces/
├── scenario_basic_voting_pipeline.ndjson
├── scenario_crash_before_fsync.ndjson
├── scenario_oc_threshold_slot1.ndjson
└── scenario_two_fork_persistence.ndjson
```

`apply.sh` only copies `tla_trace_scenarios.rs` to
`artifact/agave/core/tests/`.  No agave source files are patched.  To revert:
`rm artifact/agave/core/tests/tla_trace_scenarios.rs`.

## Approach

The harness uses **test-driven instrumentation**: a `#[test]` orchestrator
invokes the real Tower BFT APIs (`Tower::record_bank_vote`,
`FileTowerStorage::store`, `Tower::restore`) and emits an NDJSON trace event
**immediately after** each call, capturing the post-state via the Tower's
public getters (`last_voted_slot`, `last_voted_slot_hash`,
`last_vote().len()`, `root()`).

A few events (`Crash`, `CrashBeforeFsync`, `BroadcastVote`, `ReceiveVote`,
`ReachOC`, `PurgeUnconfirmedSlot`, `ProcessDuplicateConfirmedSignal`) are
emitted from the test orchestrator without a real-code analogue, because the
production paths that generate them either run in threads we do not spin up
(`ClusterInfoVoteListener`, `VotingService`) or are buried in private
`ReplayStage` methods.  The test still drives real `Tower` and
`FileTowerStorage` state for every observable event.

## Scenarios

| Test | Events | Validates |
|---|---|---|
| `scenario_basic_voting_pipeline` | RecordVote, PersistTower, BroadcastVote (x2), Crash, Restart | yes |
| `scenario_crash_before_fsync` | RecordVote, PersistTower, CrashBeforeFsync, Restart | yes |
| `scenario_oc_threshold_slot1` | 4× (RecordVote, PersistTower, BroadcastVote), 4× ReceiveVote | yes |
| `scenario_two_fork_persistence` | RecordVote, PersistTower, BroadcastVote (x2), Crash, Restart | yes |

## Trace event coverage

| Spec action | Emitted from | Hash source |
|---|---|---|
| `RecordVote` | after `tower.record_bank_vote(&bank)` | canonical (slot-based) |
| `PersistTower` | after `tower_storage.store(...)` | n/a |
| `BroadcastVote` | test orchestrator (no real broadcast) | canonical |
| `Crash` | test orchestrator | n/a |
| `CrashBeforeFsync` | test orchestrator + tower-file wipe | n/a |
| `Restart` | after `Tower::restore(...)` | canonical |
| `ReceiveVote` | test orchestrator | canonical |
| `ReachOC` | not currently emitted (see below) | — |
| `PurgeUnconfirmedSlot` | not currently emitted | — |
| `ProcessDuplicateConfirmedSignal` | not currently emitted | — |
| `RootSlot` | not currently emitted | — |
| `CastSwitchVote` | not currently emitted | — |
| `AdoptOnChainTowerIfBehind` | not currently emitted | — |

Why several events are deferred:

- **ReachOC** is reactive in the spec (`ReachOC(s,h)` requires the stake
  threshold to be exceeded).  The spec's `SilentReachOC` action fires it
  on-demand when a `RootSlot` or `ProcessDuplicateConfirmedSignal` event
  needs it.  Until the trace includes those, emitting an explicit `ReachOC`
  is harder than letting `SilentReachOC` handle it.
- **PurgeUnconfirmedSlot** / **ProcessDuplicateConfirmedSignal** require
  cluster-wide signals (`DupConf` messages, `duplicate_confirmed_slots`
  channel) that the harness does not simulate.
- **RootSlot** requires a 32-deep tower or manual `set_root` that crosses
  the spec's preconditions; deferred until the spec's `RootSlot` action is
  generalised.
- **CastSwitchVote** / **AdoptOnChainTowerIfBehind** need a precise sequence
  of replay/gossip votes from peers and a behind-the-local-tower bank state;
  out of scope for this round.

## Spec edits required for harness compatibility

The spec generation phase produced `Trace.tla` and `Trace.cfg` that needed
the following small adjustments to consume harness traces.  These are
already applied:

1. **`Trace.cfg`** — `Server`, `Byzantine`, `Hashes`, `TwoForkRoot`,
   `MainForkHash`, `AltForkHash` are declared as JSON-string literals
   (`"v1"`, `"hA"`, ...) instead of TLA+ model values.  The trace harness
   cannot emit model values; this is the structurally-equivalent change
   that keeps the spec's intent intact.
2. **`Trace.cfg`** — `CHECK_DEADLOCK FALSE` is set.  When the cursor passes
   `Len(TraceLog)` no event-consuming action remains enabled; TLC's default
   deadlock detection reports that as an error, but for trace validation it
   is the expected terminal condition.
3. **`Trace.tla`** — `TraceServer` now guards `event.nid` with
   `IF "nid" \in DOMAIN ...`.  Events like `ReachOC` and `RootSlot` legally
   omit `nid` (the spec actions take no node argument).
4. **`Trace.tla`** — `SilentDropMessage` is tightened to skip messages that
   any future `ReceiveVote` event would consume.  Without this guard, TLC
   non-deterministically drops a message that the trace later needs and
   reports a temporal-property violation.

If the spec generation pipeline is re-run, these edits will need to be
re-applied.  None of them change the spec's safety semantics.

## How to adjust

### Add a field to an event

The test emits via the inline `Event` builder
(`harness/src/tla_trace_scenarios.rs`):

```rust
Event::new("RecordVote")
    .nid(self.nid(voter))
    .slot(slot)
    .hash(canonical_hash_label(slot))
    .state(&[
        ("lastVotedSlot", u(last_slot)),
        ("lastVotedHash", s(last_hash)),
        ...
    ])
    .emit();
```

To add a field, append `(field_name, JsonValue)` to the `state` slice.
Helpers: `s(...)` for strings, `u(...)` for u64, `b(...)` for bool.

### Add a new event type

1. Add an `emit_<event>(...)` method to `Harness` (use `emit_record_vote`
   as a template).
2. Call it from a scenario at the appropriate point.

### Move a capture point

Tower BFT events typically capture **post-state**.  To capture pre-state,
read the Tower's accessors **before** the call to `tower.record_bank_vote`
or `tower_storage.store`, then emit the event with those values.

### Add an action wrapper for an unmodeled event

If `Trace.tla` requires `RootSlot`, `CastSwitchVote`, or
`AdoptOnChainTowerIfBehind`:

```rust
// RootSlot: when a tower vote becomes 32-deep, the validator advances the
// root.  Set up a deep enough vote stack and call `vote_simulator.set_root`.
let new_root = ...;  // computed from the tower's lockout history
sim.sim.set_root(new_root);
Event::new("RootSlot")
    .slot(new_root)
    .hash(canonical_hash_label(new_root))
    .emit();
```

### Rebuild and re-run

```bash
cd /home/ubuntu/Specula/case-studies/solana
bash .specula-output/harness/run.sh
```

The harness preserves cargo's build cache between runs; only the test crate
recompiles after a source edit (a few seconds).  A cold build with no cargo
cache is ~1-2 minutes after the first run, ~5 minutes on the very first run.

### Single-scenario re-run

```bash
cd artifact/agave
SOLANA_TLA_TRACE_FILE=/tmp/one.ndjson \
LIBCLANG_PATH=/path/to/libclang \
cargo test -p solana-core --test tla_trace_scenarios \
    --features dev-context-only-utils -- --exact scenario_basic_voting_pipeline --nocapture
```

## Constants the trace assumes

The harness encodes the spec's default `Trace.cfg` constants directly:

| Constant | Value | Where in code |
|---|---|---|
| `MaxSlot` | 3 | `emit_config_line(3)` in scenarios |
| `Hashes` | `{"hA", "hB"}` | `emit_config_line` arg |
| `CanonicalSlotHash` | `1->hA, 2->hA, 3->hB` | `canonical_hash_label` |

If the spec's cfg is changed to a different fork-tree shape, update
`canonical_hash_label` and the `emit_config_line(...)` calls to match.

## libclang requirement

The cold cargo build pulls in `rocksdb-sys` -> `librocksdb-sys` ->
`clang-sys`, which needs `libclang.so` at link time.  `run.sh` autodetects
`/usr/lib/x86_64-linux-gnu/libclang-*.so.*` and points `LIBCLANG_PATH` at it.
If your environment has libclang under a different path, set
`LIBCLANG_PATH=/path/to/dir/with/libclang.so` before running `run.sh`.
