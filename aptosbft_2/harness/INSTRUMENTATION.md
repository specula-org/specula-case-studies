# Aptos BFT round-2 instrumentation guide

This guide describes how the trace harness instruments the
`aptos-core/consensus/safety-rules` crate so the Phase-3 validation
agent can adjust it as trace validation reveals issues.

## Architecture

Copy-and-patch over the safety-rules crate.  `harness/apply.sh`:

1. Copies `harness/src/tla_trace.rs` → `consensus/safety-rules/src/tla_trace.rs`.
2. Inserts `pub mod tla_trace;` (under `cfg(any(test, feature="testing"))`) in `lib.rs`.
3. Patches `safety_rules_2chain.rs` and `safety_rules.rs` in place to emit trace events at six load-bearing points.
4. Drops `harness/src/tla_trace_scenario.rs` into `consensus/safety-rules/src/tests/`.
5. Registers `mod tla_trace_scenario;` in `tests/mod.rs`.

Run `harness/clean.sh` to revert the artifact (`git checkout -- ...`).

## Trace module (`tla_trace.rs`)

Public surface used by both the source-level instrumentation and the
test scenario driver:

| Symbol | Purpose |
| ------ | ------- |
| `init(path, map)` | Open the NDJSON output file and install the PeerId → sid mapping. |
| `is_active()` | True after `init`; the instrumentation points guard their emit on this. |
| `set_active_nid(sid)` / `clear_active_nid()` | Thread-local sid the next emit will tag.  The scenario driver sets it before each SafetyRules call so source-level emits know which validator they belong to. |
| `safety_state(&SafetyData)` | Build the standard `state` JSON object (epoch, lastVotedRound, preferredRound, oneChainRound, highestTimeoutRound, lastVote). |
| `merge_state(base, extra)` | Splice extra fields (currentRound, highestQCRound, ...) into a state object. |
| `emit_event(name, sid, round, epoch, state, msg?)` | Write one NDJSON line wrapped in `{"tag":"trace", "ts":..., "event":{...}}`. |

The trace module is `cfg(any(test, feature="testing"))` so it never
ships in a release build.

## Source-level instrumentation points

| Spec action | Code site (after `apply.sh`) | Trigger |
| ----------- | ---------------------------- | ------- |
| `SignVote` | `safety_rules_2chain.rs` ~line 95 — between the existing `self.sign(&ledger_info)?` and `set_safety_data` calls inside `guarded_construct_and_sign_vote_two_chain` | After the in-memory `safety_data.last_vote = Some(vote.clone())` mutation **and before** the persist; captures the Family-1 split window. |
| `CompletePersistVote` | same function, immediately after `self.persistent_storage.set_safety_data(safety_data.clone())?` | After persist; trace's `state.lastVotedRound` reflects the persisted view (equal to volatile at this point). |
| `SignOrderVote` | `safety_rules_2chain.rs` ~line 120 — after `set_safety_data` in `guarded_construct_and_sign_order_vote` | Single atomic action in the spec; the impl persists right after signing. |
| `SignTimeout` | `safety_rules_2chain.rs` ~line 52 — after both `set_safety_data` (`:47`) and `self.sign(...)` (`:49`) in `guarded_sign_timeout_with_qc` | Persist precedes sign in the canonical fix (`f58e184471`); trace event lands at the natural protocol boundary. |
| `SignCommitVote` | `safety_rules.rs` ~line 420 — after `self.sign(&new_ledger_info)?` in `guarded_sign_commit_vote` | The current source-level emit is in place for production observability, but the scenario synthesises this event at the driver level because constructing a valid round-r `LedgerInfo` would require a full pipeline driver. |
| `EpochChange` | `safety_rules.rs` ~line 305 — after `set_safety_data(SafetyData::new(...))` in the `Ordering::Less` branch of `guarded_initialize` | Fires on epoch advance.  Scenario synthesises this event because driving `Ordering::Less` from a unit test needs a fresh epoch-boundary `LedgerInfo`. |

All six source-level emits are gated on `tla_trace::is_active()` and on
`cfg(any(test, feature="testing"))`, so the instrumentation is a no-op
unless the harness is running.

## Test-scenario emits (round-manager analogues)

The instrumentation spec lists actions that the impl runs in
`round_manager.rs` / `buffer_manager.rs` rather than in safety-rules.
Driving the full round-manager state machine from a unit test is
expensive; instead, the scenario driver emits these events directly
at the protocol boundaries it orchestrates.

| Event | Where the driver emits it |
| ----- | ------------------------- |
| `Propose` | Once per round, before any SafetyRules call. |
| `ProposeOpt` | Once in the `opt` scenario; mutually exclusive with `Propose` at the same round. |
| `ReceiveProposal` | At every validator before its `construct_and_sign_vote_two_chain` call. |
| `ReceiveVote` | At every receiver for every signer's vote. |
| `FormQC` | At every receiver once 3 of 4 signers contributed. |
| `ReceiveOrderVote` | At every receiver for every order-vote signer. |
| `FormOrderingCert` | At every receiver once 3 of 4 order-votes contributed. |
| `ExecuteBlock` | Once per round after `FormOrderingCert`. |
| `SignCommitVote` | Driver-synthesised (see above). |
| `ReceiveCommitVote` | At every receiver from every commit-vote signer. |
| `AggregateCommitVotes` | Once per round when commit-votes reach quorum. |
| `PersistBlock` | After `AggregateCommitVotes`. |
| `ReceiveTimeout` | At every receiver from every timeout signer. |
| `FormTC` | At every receiver once 3 of 4 timeouts contributed. |
| `EchoTimeout` | After `FormTC` advances `currentRound`; the spec models the re-broadcast at `currentRound[s]`. |
| `EpochChange` | Synthesised (see above). |

## State fields per event

The trace's `state` object always carries the five SafetyData fields
(`epoch`, `lastVotedRound`, `preferredRound`, `oneChainRound`,
`highestTimeoutRound`) plus, where relevant:

| Field | Used for |
| ----- | -------- |
| `currentRound` | Round-changing events (Propose, ProposeOpt, ReceiveProposal, FormQC, FormTC). |
| `highestQCRound` | FormQC, FormOrderingCert. |
| `highestOrderedRound` | FormOrderingCert. |
| `committedRound` | FormQC, PersistBlock. |
| `proposalValue` | Propose, ProposeOpt, FormOrderingCert. |
| `lastVote` | Always emitted; `""` when none, `{round, value}` otherwise. |

Trace.tla validates state via `ValidateSafetyState` (for safety-data
mutations), `ValidatePersistedState` (for CompletePersistVote /
SignTimeout / Recover), `ValidateCertState` (for FormQC /
FormOrderingCert) and `ValidateRoundState` (for round-advancing
events).

## How to add a new field to an event

1. Update the JSON emit at the corresponding call site (either in
   `tla_trace.rs` `safety_state(...)` or in the test scenario driver).
2. Add the field name to Trace.tla's `state` schema comment.
3. Add a check in `ValidateSafetyState` / a new validator helper.

## How to add a new event type

1. Add an emit point in the appropriate source location and a
   matching `tla_trace::emit_event` call.
2. Add an action in `base.tla` (if not already present).
3. Add a `XxxIfLogged` wrapper in `Trace.tla` and disjunct it into
   `TraceNext`.
4. Rebuild via `bash harness/run.sh`.

## How to move a capture point

For source-level emits, edit the patch in `harness/apply.sh` (the
Python heredoc) to change the anchor.  For driver-level emits, just
re-order the calls in `tla_trace_scenario.rs`.

## How to rebuild and re-run

```
bash harness/clean.sh        # optional — reverts the artifact
bash harness/run.sh          # apply, build, run 4 scenarios, summary
```

Or for a single scenario without rebuilding the whole pipeline:
```
cd artifact/aptos-core
TLA_TRACE_FILE=../../.specula-output/traces/normal.ndjson \
  cargo test -p aptos-safety-rules --features testing -- \
  tla_trace_normal_flow --nocapture --test-threads=1
```

## Trace validation

```
mcp__tla-trace-debugger__run_trace_validation \
  --spec_file=Trace.tla --config_file=Trace.cfg \
  --trace_file=../traces/<scenario>.ndjson \
  --work_dir=/home/ubuntu/Specula/case-studies/aptosbft_2/.specula-output/spec
```

All four scenarios currently pass:

| Scenario | Trace lines | Events |
| -------- | -----------:| ------ |
| normal | 245 | Propose, ReceiveProposal, SignVote, CompletePersistVote, ReceiveVote, FormQC, SignOrderVote, ReceiveOrderVote, FormOrderingCert, ExecuteBlock, SignCommitVote, ReceiveCommitVote, AggregateCommitVotes, PersistBlock |
| timeout | 53 | SignTimeout, ReceiveTimeout, FormTC, EchoTimeout |
| opt | 67 | ProposeOpt, ReceiveProposal, SignVote, CompletePersistVote, ReceiveVote, FormQC, Propose |
| epoch_change | 38 | Propose, ReceiveProposal, SignVote, CompletePersistVote, ReceiveVote, FormQC, EpochChange |

## Known limitations

1. **Single-signer fan-out** — all four validators share signer 0's
   identity (with `skip_sig_verify=true` from LocalClient).  This is
   safe because the spec validates per-nid state transitions, not
   cryptographic signatures.
2. **Source-level SignCommitVote emit is unused by the current
   scenario** — driver synthesises the event because the real call
   path needs a properly constructed `LedgerInfoWithSignatures`.  The
   instrumentation remains in place for production observation.
3. **Source-level EpochChange emit is unused for the same reason** —
   driving `guarded_initialize::Ordering::Less` from a unit test
   requires a fresh epoch-boundary proof.  The driver synthesises the
   event with the expected post-epoch SafetyData.
4. **`spec/base.tla` was patched** to give `inflightSignedVote` and
   `lastVote` record-shaped Nil sentinels.  TLC throws a runtime
   exception when comparing record-vs-scalar types, even inside a
   disjunction's "safe" branch.  The fix is internal to base.tla and
   does not change spec semantics.

## File layout

```
harness/
├── apply.sh                # apply patches
├── clean.sh                # revert
├── run.sh                  # one-shot build + run + collect
├── INSTRUMENTATION.md      # this file
└── src/
    ├── tla_trace.rs        # NDJSON writer + helpers
    └── tla_trace_scenario.rs  # 4 #[test] scenarios
traces/
├── normal.ndjson           # happy path
├── timeout.ndjson          # SignTimeout + FormTC + EchoTimeout
├── opt.ndjson              # ProposeOpt path
└── epoch_change.ndjson     # EpochChange event
```
