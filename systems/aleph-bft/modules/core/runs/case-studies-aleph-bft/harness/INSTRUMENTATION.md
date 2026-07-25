# Trace Instrumentation — AlephBFT

This document explains where each spec-action emit lives, how to extend the
harness, and what known gaps a Phase 3 spec-validation agent should be aware
of.

## Layout

```
.specula-output/harness/
├── apply.sh                         # idempotent: revert + reapply patch
├── run.sh                           # one-command build + run + collect
├── INSTRUMENTATION.md               # this file
├── patches/
│   └── instrumentation.patch        # git patch over consensus/src
└── src/
    ├── tla_trace.rs                 # trace emitter (Rust)
    └── trace_scenario.rs            # trace-collecting test scenarios
```

`apply.sh` always (a) reverts `consensus/src/` to the upstream checkout, (b)
copies `src/tla_trace.rs` to `artifact/AlephBFT/consensus/src/tla_trace.rs`
and `src/trace_scenario.rs` to
`artifact/AlephBFT/consensus/src/testing/trace_scenario.rs`, then (c)
applies `patches/instrumentation.patch`.  The patch wires the new modules
into `lib.rs` / `testing/mod.rs` and inserts emit calls into the existing
files.

## How the trace module is activated

The trace writer initializes lazily on the first emit and opens a file at
the path in the environment variable `TLA_TRACE_FILE`.  When that variable
is unset the writer stays `None` and every `emit_*` returns immediately, so
the instrumented build behaves identically to the upstream artifact during
normal `cargo test` runs.

Activate by exporting `TLA_TRACE_FILE` before invoking `cargo test`:

```bash
TLA_TRACE_FILE=/abs/path/trace.ndjson \
  cargo test -p aleph-bft --tests trace_four_honest_all_alive \
  -- --test-threads=1
```

## Event hooks — where each emit lives (after `apply.sh`)

All paths are relative to `artifact/AlephBFT/`.

| Spec action                       | File                            | Trigger point |
|-----------------------------------|---------------------------------|---------------|
| `Sign`                            | `consensus/src/consensus/service.rs` | `on_unit_reconstructed`, restricted to `unit.creator() == self.handler.node_index()` (own units only). Emit happens before `backup_units_for_saver.unbounded_send`. |
| `PersistUnit`                     | `consensus/src/backup/saver.rs`      | After `save_unit().await?` returns Ok, restricted to `item.creator() == self.node_index` (matches the spec's own-units-only semantics). |
| `BroadcastUnit`                   | `consensus/src/consensus/service.rs` | `on_unit_backup_saved`, restricted to `unit.creator() == node_id` AND only when `handler.on_unit_backup_saved` returns `Some(broadcast_msg)` (the impl's first-broadcast signal). |
| `DeliverUnit`                     | `consensus/src/dag/validation.rs`    | `validate()` Ok branch, restricted to `unit.creator() != self.unit_validator.index()` (network units only). |
| `DetectFork`                      | `consensus/src/dag/validation.rs`    | `validate()` NewForker branch — emits forker, u_new, u_canon, post-state localForkers count. |
| `ReceiveAlert`                    | `consensus/src/alerts/handler.rs`    | `on_network_alert` — two paths: `repeated:true` on the `RepeatedAlert` branch (line 204), `repeated:false` on the new-forker branch (after `rmc_alert`). |
| `ConfirmAlert`                    | `consensus/src/alerts/handler.rs`    | `alert_confirmed` — after `verify_commitment`, with `outcome:"ok"` or `outcome:"badCommitment"` depending on the result. |
| `ApplyForkingNotificationUnits`   | `consensus/src/dag/mod.rs`           | `process_forking_notification` Units arm — the shadow counter `committed_units` is bumped by the number of newly-admitted units.  **Note:** the alert payload is not available here, so this branch currently only updates the counter; it does not emit a standalone `ApplyForkingNotificationUnits` event.  See "Known gaps" below. |
| `RunElection`                     | `consensus/src/extension/mod.rs`     | `Ordering::add_unit`, when a batch is produced — emits the head's `{creator, round}`. |
| `RestartLoadBackup`               | not yet wired                        | Backup-recovery scenarios are not yet exercised by the test scenarios. |
| `RestartStartingRound`            | not yet wired                        | Same. |
| `Crash`                           | not yet wired                        | The harness does not currently inject mid-session crashes; only the upstream graceful-exit path runs. |
| `ByzantineFork` / `ByzantineRaiseBadAlert` | not yet wired                | Honest-only scenarios. |

## Shadow counters

Several `state` fields don't map directly to impl variables.  `tla_trace.rs`
maintains per-node shadow counters:

| Counter                | Incremented at                                | Decremented at      |
|------------------------|-----------------------------------------------|---------------------|
| `in_flight`            | `Sign` emit (own unit queued to saver)        | `PersistUnit` emit  |
| `persisted`            | `PersistUnit` emit                            | never (monotone)    |
| `broadcast`            | `BroadcastUnit` emit                          | never               |
| `all_units`            | `BroadcastUnit`, `DeliverUnit`, ApplyForkingNotificationUnits committed-batch | never |
| `confirmed_alerts`     | `ConfirmAlert` emit, only on `outcome:"ok"`   | never               |
| `committed_units`      | `ApplyForkingNotificationUnits` per accepted unit | never            |

`all_units` is a dedicated counter (not derived from `store.size() +
processing_units.size()`) because the impl's `processing_units` would
over-count during the Sign-to-BroadcastUnit window for own units. See the
docstring on `Counters::all_units` in `tla_trace.rs`.

`reset_counters(node)` clears the per-node table; the test scenario calls
it for every member at the start of each run so repeated `cargo test`
invocations don't carry counters across runs.

## How to add a new event type

1. Add an `emit_<name>(...)` function in `tla_trace.rs`.  Mirror the
   pattern from `emit_sign` / `emit_deliver_unit`: build the unit/alert
   JSON via the existing helpers, build the state JSON via
   `state_for_node`, then call `write_line`.
2. Add a call to the emitter at the relevant code path in the artifact,
   gated by `#[cfg(test)]` so production builds are unaffected.
3. Add a wrapper in `Trace.tla` (see the existing wrappers in the spec
   file).
4. Re-generate the patch:  
   `cd artifact/AlephBFT && git diff > ../../.specula-output/harness/patches/instrumentation.patch`.

## How to add a new state field to an existing event

1. Add the field to the relevant `Counters` slot (if it's a shadow
   counter) or thread it as an argument into the `emit_*` function.
2. Update `state_for_node` to include the new field.
3. Update the corresponding `Validate<Field>(i)` wrapper in `Trace.tla` so
   the spec validates it.
4. Regenerate the patch.

## How to move an emit from "before" to "after" a code action

Just move the `#[cfg(test)] { crate::tla_trace::emit_*(...) }` block.
Captures occur at emit time, so post-state is always reflected by the
shadow counters and whatever live values you pass.  The patch only adds
trace blocks; everything else stays untouched.

## How to rebuild after editing the trace module

The trace module lives in the artifact's `consensus` crate, gated by
`#[cfg(test)]`.  After editing:

```bash
cd .specula-output
bash harness/run.sh        # reverts, copies fresh sources, rebuilds, runs scenarios
```

For incremental iteration during dev, you can also work directly in the
artifact tree and just re-export the patch when satisfied.

## Known gaps that Phase 3 should be aware of

### 1. Sign action: state-space explosion

`base.tla`'s `Sign(n, r)` action uses
`\E parents \in SUBSET [creator: Node, round: Round]`.  For `Node = 4` and
`MaxRound = 6` that's `SUBSET` over 28 elements, which TLC explores too
slowly to be tractable on the full trace.  Phase 3 should either:

- Tighten `SignIfLogged` in `Trace.tla` to bind `parents` from
  `logline.event.unit.parents` (constraining `\E parents` to the unique
  set encoded in the trace), or
- Restrict `parents` to the canonical store membership at the start of the
  Sign action body.

With `MaxRound = 2`, the existing spec already validates the first 48
events end-to-end.

### 2. DeliverUnit: eager-evaluation guard

The original `base.tla` line 460-461 used
```
/\ \/ CoordOf(u) \notin DOMAIN canonical[n]
   \/ canonical[n][CoordOf(u)] = u.variant
```
which TLC evaluates eagerly (both disjuncts), failing on
`canonical[n][CoordOf(u)]` when the coord is not in the domain. The patch
in this harness rewrites it to:
```
/\ IF CoordOf(u) \in DOMAIN canonical[n]
   THEN canonical[n][CoordOf(u)] = u.variant
   ELSE TRUE
```
which is TLC-safe. Phase 3 should keep this fix and apply the same pattern
to any other guard in the spec that uses eager disjunction with a
function-domain check.

### 3. `Node` configured as integers

The original `Trace.cfg` had `Node = {n1, n2, n3, n4}` (model values). The
harness emits NodeIndex as integers, so the cfg has been updated to
`Node = {0, 1, 2, 3}`.  A backup mini-cfg at `Trace-mini.cfg` and an
`MaxRound = 2` cfg at `Trace-r2.cfg` are provided for iterative work.

### 4. Honest-only coverage today

The current scenarios exercise only the unit-creation, persistence,
broadcast, delivery, and extension paths. They do not fire `DetectFork`,
`ReceiveAlert`, `ConfirmAlert`, `ApplyForkingNotificationUnits`,
`ByzantineFork`, `ByzantineRaiseBadAlert`, or the restart actions
(`Crash`, `RestartLoadBackup`, `RestartStartingRound`,
`RecordNewestResponse*`). Hooks for the alerter and apply-forking-units
flows are wired but won't fire without fault injection. Phase 3 or a
future iteration should add scenarios that:

- Inject a Byzantine forker (modify `Creator` to emit two variants at the
  same round) to exercise the alerter chain.
- Inject crashes via `Terminator::terminate_sync` mid-session to exercise
  the backup/restart chain.

### 5. `ApplyForkingNotificationUnits` event omission

`Dag::process_forking_notification`'s Units arm does not have access to
the originating `Alert` object (only the `legit_units` list). The
counter `committed_units` is updated correctly, but a standalone
`ApplyForkingNotificationUnits` JSON event is not currently emitted. To
emit one, you'd need to either:

- Thread the originating alert through `process_forking_notification`'s
  signature, or
- Emit from `alerts/service.rs::handle_multisigned`, where the full alert
  is in scope, and call into the dag from there.

### 6. Trace event ordering across async tasks

Tokio runs the consensus core, alerter, backup saver, and creator as
independent tasks.  Trace lines are mutex-serialized so the file order is
well-defined, but the order of events between tasks can interleave in
ways that the spec's per-node `lastSignedRound` / `inFlightUnits` view
already tolerates.  In rare orderings, a `DeliverUnit` line may appear in
the trace before the `BroadcastUnit` that produced its source message at
a different node — but the spec's `[kind |-> "unit", ...] \in msgs`
precondition is satisfied because BroadcastUnit at the sender always
precedes DeliverUnit at the receiver in the impl's causal order (the
network channel forces this).
