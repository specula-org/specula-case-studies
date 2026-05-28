# Instrumentation Guide (Phase 3 Companion)

This is a short guide for the Phase 3 agent who tunes the instrumentation when
trace validation surfaces issues. Read `instrumentation-spec.md` for the high
level mapping; this file documents what's actually wired in.

## Layout

```
harness/
  apply.sh                — copies instrumented files into the artifact
  clean.sh                — reverts the artifact to pristine state (`git checkout`)
  run.sh                  — apply + cargo build --release + run scenarios + collect traces
  src/
    migration.rs          — instrumented version of votor-messages/src/migration.rs
    tla_trace.rs          — trace emission module (added as `pub mod tla_trace` in lib.rs)
    votor_messages_lib.rs — replacement votor-messages/src/lib.rs (adds `pub mod tla_trace`)
    votor_messages_Cargo.toml — replacement Cargo.toml (adds the `tla-trace` feature)
  scenarios/              — standalone Cargo crate that depends on the patched
                            agave-votor-messages and drives test scenarios
    Cargo.toml
    src/{common.rs,happy_path.rs,startup_poh_race.rs,panic_paths.rs}
```

`run.sh` is idempotent: it re-applies the instrumentation each run by first
restoring the artifact via `git checkout`.

## Reproduction

```bash
bash /home/ubuntu/Specula/case-studies/solana_4/.specula-output/harness/run.sh
```

Produces `.specula-output/traces/{happy-path,startup-poh-race,panic-paths}.ndjson`.

Validate with:

```bash
# Anywhere inside .specula-output/spec/
tlc Trace.tla -config Trace.cfg
```

or via the trace debugger MCP:

```python
run_trace_validation(
    spec_file="Trace.tla",
    config_file="Trace.cfg",
    trace_file="../traces/happy-path.ndjson",
    work_dir=".specula-output/spec/")
```

All three traces (`happy-path`, `startup-poh-race`, `panic-paths`) currently
pass cleanly under TLC.

## Instrumentation points (after `apply.sh`)

All locations are inside `artifact/agave/votor-messages/src/migration.rs`.
Look for the markers `// >>> TLA_TRACE …` and `// <<< TLA_TRACE`.

| Event name                       | Function in migration.rs            | Notes |
|----------------------------------|--------------------------------------|-------|
| `RecordFeatureActivation`        | `record_feature_activation`          | emits on success + on the assert-fail path |
| `SetGenesisBlock`                | `set_genesis_block`                  | `path` field disambiguates the 5 spec actions |
| `SetGenesisCertificate`          | `set_genesis_certificate`            | `path` field disambiguates the 4 spec actions |
| `EnableAlpenglow`                | `enable_alpenglow`                   | suppressed when nested in `enable_alpenglow_during_startup` (PoH branch) |
| `EnableAlpenglowDuringStartup`   | `enable_alpenglow_during_startup`    | emits on both PoH branches and the panic path |
| `SetPohServiceStarted`           | `set_poh_service_started`            | race injector |
| `AlpenglowRootedNewEpoch`        | `alpenglow_rooted_new_epoch`         | success only — panic path is currently not in the spec |

State snapshot fields captured for every event:
`phase`, `ff_activation_slot`, `migration_slot`, `genesis_block`,
`genesis_cert`, `poh_service_started`, `shutdown_poh`, `panicked`.

## Shadow fields added to `MigrationStatus`

| Field | Purpose |
|---|---|
| `nid: RwLock<Option<String>>` | spec-friendly node id (`set_trace_nid("h1")`) used as the trace `nid`. Defaults to `my_pubkey.to_string()` if unset. |
| `ff_activation_slot_shadow: AtomicU64` | persists `ff_activation_slot` after the impl drops the `Migration { … }` variant. `u64::MAX` ⇔ `NoSlot`. |
| `panicked: AtomicBool` | set before each `assert!`/`panic!`/`unreachable!` so the trace event carries `panicked = true`. |

The harness derives `migration_slot` from `ff_activation_slot_shadow + MIGRATION_SLOT_OFFSET`
so it persists across all post-Migration phases (matches the spec's
`migrationSlotV` semantics).

## Sentinel-encoding contract with the spec

The trace emitter and the trace spec agree on these conventions:

* `NoSlot` ⇔ integer `999` (Trace.cfg pins `NoSlot = 999`).
* `NoBlock` ⇔ record `[slot |-> 999, bid |-> "NoBlock"]` (defined in base.tla).
* `NoCert`  ⇔ record `[cert_type |-> "CertGenesis", slot |-> 999, block_id |-> "NoCert"]` (defined in base.tla).

Keeping sentinels in the same type-family as the concrete value lets TLC
compare them without tripping its strict-type guard.

Slot bound: `MaxSlot = 6`, `MigrationSlot = 5`, `FeatureSlot = 0`. To honour
that, the harness compiles `agave-votor-messages` with the `tla-trace` feature,
which sets `MIGRATION_SLOT_OFFSET = 5` (instead of 32 / 5000).

## Adding a new field to an existing event

1. Add a getter to `MigrationStatus` (e.g. a new `AtomicU64` shadow).
2. Extend `StateSnapshot` in `harness/src/tla_trace.rs` and its `to_json`.
3. Extend the corresponding `Validate*PostState(v)` operator in
   `spec/Trace.tla`.
4. Re-run `harness/run.sh` and re-validate.

## Adding a new event type

1. Pick the function whose execution carries the spec action.
2. Insert `self.emit("YourEventName", vec![("k".into(), "<json>".into()), …])`
   at the trigger point.
3. Add a wrapper in `Trace.tla`:

   ```tla
   YourEventIfLogged ==
       \E v \in Validator :
           /\ IsNodeEvent("YourEventName", v)
           /\ YourEvent(v, logline.event.somefield)
           /\ ValidateMigrationPostState(v)
           /\ StepTrace
   ```

   And disjunct it into `TraceNext`.
4. Re-run `harness/run.sh` and re-validate.

## Moving a capture point (before ↔ after)

`emit("Foo", …)` reads `self.snapshot()`. If you move the emit call **before**
the mutation, the state shows the pre-state. After the mutation, it shows the
post-state. The current convention is **post-state for every event**
(matches `ValidateMigrationPostState`).

For events that branch into "success" and "panic" outcomes (e.g.
`SetGenesisBlock`), the emit happens AFTER the inspection-and-mutation step
but BEFORE the panic — that way the trace observes the bug condition with
`panicked = true` before the thread unwinds.

## Coverage limitations (out-of-scope for this harness)

The instrumentation spec defines events spread across many crates of the
agave workspace. To keep build time bounded, this harness only instruments
`votor-messages/src/migration.rs`. The following events from the spec are
**not yet emitted**:

| Family | Missing events | Reason |
|---|---|---|
| 1 (block_component) | `BlockComponentSetGenesisChain` | lives in `runtime/src/block_component_processor.rs`, depends on solana-runtime |
| 2 | `ComputeSuperOC`, `DiscoverGenesisBlock` | live in `core/src/consensus.rs` and `core/src/replay_stage.rs` |
| 3 | `IngestGenesisVote`, `BuildGenesisCert` | live in `votor/src/consensus_pool*` |
| 4 | `IngestNotarFallbackVote`, `BuildNotarFallbackCert` | live in `votor/src/consensus_pool*` |
| 5 | `RecordVote`, `GenerateVoteTxSuccess`, `GenerateVoteTxTransientFail`, `VotingServicePersist`, `SetRoot`, `Crash`, `Recover` | live in `votor/src/voting_*` |
| 6 | `EmitStandstill`, `ProcessStandstill`, `ProcessFinalized`, `ComputeTimeout` | live in `votor/src/event_handler*` |
| 7 | `LockAcquire`, `LockRelease`, `LockGranted` | live in `core/src/replay_stage.rs` around `bank_forks.write()/read()` |

To extend coverage, add `pub mod tla_trace;` to the affected crate's lib.rs
(or re-export from `agave-votor-messages`) and insert `tla_trace::emit(...)`
calls at the spec's listed trigger points. The crate dependency boundary is
the only structural cost — the trace module itself is a single file.

Also note: case (7) in `panic_paths.rs` (AlpenglowRootedNewEpoch called from a
non-`AGEnabled` phase) is intentionally disabled. The spec's
`AlpenglowRootedNewEpoch` action is "disabled" outside `AGEnabled` rather
than modeled as a panic transition; a Phase 3 panic-wrapper would let this
case re-enter the trace.

## Spec edits made during harness bring-up

The first trace validation runs surfaced a handful of base.tla / Trace.tla
issues. Each was a localised mechanical fix; document them here so Phase 3
knows what changed:

1. `base.tla` — `\A v, cert` mixed-binding fixed in `GenesisCertWellFormed`
   and `GenesisCertBLSAggregateValid` (now nested `\A v : \A cert : ...`).
2. `base.tla` — `NoBlock` and `NoCert` are now concrete records (defined
   in base.tla, no longer CONSTANTs) so TLC can compare against concrete
   `Block(slot, bid)` records without crossing type families.
3. `Trace.cfg` — `NoSlot` is now an integer (`999`), so TLC never has to
   compare a string sentinel against a `Nat` slot.
4. `Trace.cfg` — `HonestActive`/`Byzantine` use quoted strings so they
   match the JSON-decoded `nid` strings.
5. `Trace.cfg` — removed undefined `LockHolderBound` / `StandstillWellFormed`
   from the INVARIANTS list.
6. `Trace.tla` — `TraceSpec` now conjoins `WF_<<l,vars>>(TraceNext)` so the
   `TraceMatched` liveness check doesn't trivially fail on pre-trace stutter.
7. `Trace.tla` — `TraceBlock` / `TraceCert` use the sentinel-record shape;
   `TraceSlot` is the identity since slot fields are uniformly integers.

## Rebuilding the harness

Edits to `harness/src/*.rs` or `harness/scenarios/src/*.rs` take effect on the
next `bash run.sh`. There is no separate build step — `run.sh` shells out to
`cargo build --release` against `harness/scenarios/Cargo.toml` which has a
path dependency on `artifact/agave/votor-messages`.

If `cargo build` is slow on first run, subsequent runs are incremental.
Setting `RUSTC_WRAPPER=sccache` (if installed) speeds up clean rebuilds.
