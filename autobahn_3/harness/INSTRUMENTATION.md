# Autobahn BFT — Harness & Instrumentation Guide

This is the Phase-3 cheat-sheet for adjusting the harness when trace
validation surfaces issues.  The harness instruments the *real* Autobahn
artifact (commit `bf897ef` on branch `autobahn`) — there is no simulator.

## Where everything lives

| Item | Path |
|------|------|
| Trace module | `artifact/autobahn-artifact/primary/src/tla_trace.rs` |
| Instrumented code | `artifact/autobahn-artifact/primary/src/core.rs` |
| Test scenarios | `artifact/autobahn-artifact/primary/src/tests/trace_test.rs` |
| Module wiring | `artifact/autobahn-artifact/primary/src/lib.rs` (line 26: `pub mod tla_trace;`) |
| Canonical source copies | `.specula-output/harness/src/{tla_trace.rs,trace_test.rs}` |
| Apply script | `.specula-output/harness/apply.sh` (copy + verify) |
| Run script | `.specula-output/harness/run.sh` (build + 7 scenarios + trace summary) |
| Traces | `.specula-output/traces/*.ndjson` |

`apply.sh` copies `harness/src/{tla_trace.rs,trace_test.rs}` into the
artifact tree so edits to those canonical files take effect on the next
build.  The instrumentation patches in `core.rs` / `lib.rs` are committed
in the artifact (`cb2a415` + `bf897ef`); `apply.sh` only verifies they
are still in place.

## Trace event schema (flat NDJSON)

```json
{"event":"<Name>","node":"n2","slot":1,"view":1,"value":"v1",
 "state":{"view":1,"committed":"false"},
 "ts":"<epoch ns>", "node_map":{...} /* first event only */}
```

There is no `tag` field — `Trace.tla` filters with
`"event" \in DOMAIN x`.  Servers are named `n1`…`n4` (HashMap-iteration
order at `register_servers` time).  Values are abstracted to `v1`,
`v2`, … in first-encounter order on the proposal digest.

## Event-to-code-location map (post-apply line numbers)

| Event | core.rs line | Trigger point |
|-------|--------------|---------------|
| `SendPrepare` | 1141, 2310 | After proposer broadcasts new Prepare (view 1) |
| `ReceivePrepare` | 1519 | After `consensus_sigs.push(...)` (vote generated) |
| `SendConfirm` | 691 | After PrepareQC formed, Confirm queued |
| `SendCommitFast` | 682, 870 | Fast-path Commit branch |
| `SendCommitSlow` | 713, 898 | After ConfirmQC formed, Commit queued |
| `ReceiveConfirm` | 1563 | After `high_qcs.insert(...)` |
| `ReceiveCommit` | 1632 | After `committed_slots.insert(...)` |
| `SendTimeout` | 1847 | After Timeout broadcast (pre self-deliver) |
| `AdvanceView` | 1922 | After `views.insert(slot, view+1)` |
| `GeneratePrepareFromTC` | 1988 | After view-change Prepare broadcast |

State snapshot helpers (`core.rs:2140-2156`):
- `tla_state(slot)` → `{view, committed}`
- `tla_state_with_confirm(slot, val)` → adds `confirm_voted_value`
- `tla_value(msg)` → abstract value name (`v1`, `v2`, …)

## Test scenarios — what each one covers

| Scenario | base_port | Events triggered |
|----------|-----------|------------------|
| `tla_trace_consensus` | 18000 | one slot: ReceivePrepare → SendConfirm → ReceiveConfirm → SendCommitSlow → ReceiveCommit |
| `tla_trace_timeout` | 19000 | SendTimeout (single node, timer fires) |
| `tla_trace_multi_slot` | 20000 | 5 slots × 5 events = ~25 events (consensus pattern repeated) |
| `tla_trace_fast_path` | 21000 | ReceivePrepare → SendCommitFast (all 4 votes → 3f+1 fast QC) |
| `tla_trace_view_change` | 22000 | SendTimeout + injected timeouts → AdvanceView |
| `tla_trace_leader_prepare` | 23000 | Above + autonomous SendPrepare from n2 as leader of slot 4 |
| `tla_trace_vc_leader` | 24000 | Above + GeneratePrepareFromTC (view-change leader for (3, 2)) |

## Coverage from a fresh `run.sh`

```
14 ReceivePrepare
11 SendConfirm, ReceiveConfirm, SendCommitSlow, ReceiveCommit (each)
 7 SendTimeout
 2 AdvanceView
 1 SendPrepare, SendCommitFast, GeneratePrepareFromTC (each)
```

All 10 instrumented event types fire in at least one trace.

## Known spec/harness mismatches (Phase 3 to address)

1. **Initial-state warm-up missing in `Trace.tla`.**
   Every trace begins with either `ReceivePrepare` (slot=1, view=1) or
   `SendTimeout` (slot=1, view=1).  The Trace spec's `Init` predicate
   leaves `messages = {}` and `views[s][n] = 0`, so:
   - `ReceivePrepareIfLogged` cannot find a Prepare to consume.
   - `SendTimeoutIfLogged` cannot satisfy `views[s][slot] = view` (need
     view=1, have 0).

   **Why the harness emits this:** the real `Core::run` initialises
   `self.views.insert(1, 1)` at startup (`core.rs:2185`) and the test
   injects the Prepare via the *Header* channel, not through the
   network — so neither has a `tla_trace` emit at startup time.

   **Suggested Phase-3 fix (spec side):** add a silent action that
   models the genesis/bootstrap phase, e.g.:
   ```tla
   SilentBootstrapPrepare ==
       /\ l <= Len(TraceLog)
       /\ logline.event = "ReceivePrepare" /\ logline.view = 1
       /\ \E v \in Values :
            LeaderProposeView1(Leader(logline.slot, 1), logline.slot, v)
       /\ UNCHANGED l

   SilentBootstrapViews ==
       /\ l <= Len(TraceLog)
       /\ logline.event = "SendTimeout" /\ logline.view = 1
       /\ logline.node \in Honest
       /\ views' = [views EXCEPT ![logline.node][logline.slot] = 1]
       /\ UNCHANGED <<phase, committedSlots, lastVotedConsensus,
                      highQCs, highProposals, acceptedFrom,
                      aggregatorVars, gcVars, messages, byzActions>>
       /\ UNCHANGED l
   ```
   then add both disjuncts to `TraceNext`.

   Alternative (harness side, only if Phase 3 prefers): emit a synthetic
   `SendPrepare` for the leader before the test injects the Prepare —
   but that would be hand-written trace data, which violates the
   "never hand-write traces" rule.  Prefer the spec-side fix.

2. **`views` snapshot on `SendPrepare` shows `view = 0`.**
   `core.rs:2310` captures state *before* the leader installs view 1
   for the new slot.  The Trace spec's `SendPrepareIfLogged` uses
   `ValidatePostStateWeak` (only checks `views`), so the spec must
   tolerate `views'[i][slot] = 0` for SendPrepare events that proceed
   slot's first view-install.  If the validator tightens this, the
   instrumentation should move the emit call from line 2310 to *after*
   `self.views.insert(slot, 1)` (currently inside the same closure;
   look one match below the emit).

3. **`AdvanceView` `state.view` = new view, `view` field = old view.**
   `core.rs:1925` passes `timeout.view` as the `view` field, with
   `state.view` reflecting `views' = old+1`.  The spec checks
   `views'[i][slot] = logline.view + 1` (Trace.tla:230) — so the
   convention is fine.  If Phase 3 sees a validation failure here,
   double-check that `tla_state(slot)` is called *after* the
   `self.views.insert(timeout.slot, timeout.view + 1)` at line 1919.

## Common Phase-3 maintenance tasks

### Add a new field to an event

1. Edit `tla_trace.rs:127-141` (or add a new state-builder).
2. Edit the emit-site in `core.rs` (use `make_state*` to build the new state).
3. Edit `harness/src/tla_trace.rs` to mirror the change so `apply.sh`
   does not overwrite it on the next run.
4. Re-run `bash harness/run.sh`.

### Add a new event type

1. Add a `emit_<name>` wrapper to `tla_trace.rs` (mirror existing
   `emit_send_confirm` style).
2. Insert the call in `core.rs` at the trigger point.
3. Add the corresponding `<Name>IfLogged` wrapper in `Trace.tla`.
4. Mirror changes in `harness/src/` and re-run `run.sh`.

### Move a capture point (before → after)

Just move the `if tla_trace::is_active() { ... }` block in `core.rs`
and re-run.  The state snapshot is built lazily inside the `if`, so it
captures whatever `self` looks like at the moment of the emit.

### Add a new test scenario

1. Append a `#[tokio::test] #[serial]` function to
   `harness/src/trace_test.rs` (use a new `base_port` in the
   18000-29000 range; the db-path is keyed off base_port in
   `spawn_core`).
2. Append a `run_scenario "<test_name>" "<trace_name>"` call to
   `harness/run.sh`.
3. `bash harness/apply.sh && bash harness/run.sh`.

### Rebuild and re-run after any change

```bash
cd .specula-output
bash harness/run.sh        # apply + build + run all 7 scenarios
```

Per-scenario build is ~70s for the first cold compile, ~5s afterwards
(cached `target/`).  Trace generation per scenario is <10s.

## Build constraints / caveats

- The test code links against `crypto`, `store`, `config`, `network`,
  `serial_test`, and `serde_json` — all in `primary/Cargo.toml`
  since commit `cb2a415`.
- Tests are `#[serial]` because they touch shared `OnceLock<Mutex>` in
  `tla_trace.rs`; running with `--test-threads=1` is enforced by
  `run.sh`.
- Each scenario truncates its trace file via `TLA_TRACE_FILE` (the
  trace writer opens with `truncate(true)`).  Re-running a single
  scenario overwrites its trace.
- `tla_trace::try_init` is a no-op when `TLA_TRACE_FILE` is unset, so
  the normal `cargo test` workflow (e.g. CI) is unaffected.
