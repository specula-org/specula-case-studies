# Autobahn BFT Harness — Instrumentation Guide

## Overview

This harness instruments two Rust crates:
- **`primary`** — the Autobahn BFT consensus layer (`primary/src/core.rs`)
- **`hotstuff`** — the embedded HotStuff fallback chain (`hotstuff/src/core.rs`)

Both are **Category A** (distributed message-passing): single NDJSON trace file per
scenario, mutex-protected global writer, millisecond timestamps.

---

## File Layout

```
artifact/autobahn/
├── primary/src/
│   ├── tla_trace.rs          ← trace module (global writer + node map)
│   ├── leader.rs             ← patched: keys.sort() for deterministic leader election
│   ├── core.rs               ← patched: 12 emit points + ghost state
│   └── tests/trace_scenarios.rs  ← 4 test scenarios
└── hotstuff/src/
    ├── tla_trace.rs          ← trace module (identical API to primary's)
    ├── core.rs               ← patched: 2 emit points + hs_vote_counts ghost field
    └── tests/trace_scenarios.rs  ← 2 test scenarios
```

---

## Instrumentation Points

### Primary crate (`primary/src/core.rs`)

| Event | Function | Trigger |
|-------|----------|---------|
| `SendPrepare` | `send_consensus_req` | After network broadcast, before self-processing |
| `SendConfirm` | `send_consensus_req` | Same |
| `SendCommit` | `send_consensus_req` | Same |
| `CastPrepareVote` | `process_prepare_message` | After `last_voted_consensus.insert` |
| `CastConfirmVote` | `process_confirm_message` | After signing |
| `FormPrepareQC` | `process_consensus_vote` | Inside `else if let Some(qc) = qc_opt` for Prepare |
| `FormConfirmQC` | `process_consensus_vote` | Inside `else if let Some(qc) = qc_opt` for Confirm |
| `ProcessCommit` | `process_commit_message` | After `committed_slots.insert` |
| `CleanSlotPeriods` | `clean_slot_periods` | After `retain` calls |
| `SendTimeout` | `local_timeout_round` | After broadcast, before `handle_timeout` |
| `FormTC` | `handle_timeout` | Inside `if let Some(tc) = tc_maker.append(...)` |
| `ProcessTC` | `handle_timeout` | Same block, after `views.insert` |

### HotStuff crate (`hotstuff/src/core.rs`)

| Event | Function | Trigger |
|-------|----------|---------|
| `HSMakeVote` | `make_vote` | After `increase_last_voted_round` |
| `HSProcessBlock` | `process_block` | After `if b0.round + 1 == b1.round { ... }` commit check |

### Test harness (emitted directly)

| Event | Location | Notes |
|-------|----------|-------|
| `HSCrashRecover` | `hotstuff/src/tests/trace_scenarios.rs` | Emitted between Core restarts |

---

## Ghost State

### `confirm_vote_counts` (in `primary::Core`)

Added field `confirm_vote_counts: HashMap<(Slot, View), u32>` to the `Core` struct.
Incremented in `process_confirm_message` each time a ConfirmVote is emitted.
Captured as `state.hsVoteCount` in `CastConfirmVote` events (repurposed field).

### `hs_vote_counts` (in `hotstuff::Core`)

Added field `hs_vote_counts: HashMap<(PublicKey, Round), u32>`.
Incremented in `make_vote` each time a vote is cast.
Captured as `state.hsVoteCount` in `HSMakeVote` events.

---

## How to Add a New Field to an Event

1. Open the relevant source file (e.g., `primary/src/core.rs`).
2. Find the `tla_trace::emit(...)` call for that event.
3. Add the field to the `tla_trace::State` struct at the emit point.
4. Add the field to the JSON template in `tla_trace::emit()` if it's a new top-level field
   (the current `emit()` signature already covers all spec fields; use the `proposals`,
   `voters`, `highQCView`, etc. parameters).
5. Run `cargo test -p primary -- trace_tests:: --test-threads=1` to regenerate traces.

---

## How to Add a New Event Type

Copy the pattern from an existing emit block. Example for a new `NewEvent`:

```rust
// In primary/src/core.rs at the trigger point:
{
    let nid = tla_trace::node_id(&self.name);
    let state = tla_trace::State {
        node_view: *self.views.get(&slot).unwrap_or(&0) as u64,
        ..Default::default()
    };
    tla_trace::emit("NewEvent", &nid, Some(slot as u64), Some(view as u64),
        None, None, None, None, None, None, &state);
}
```

---

## How to Move a Capture Point

The instrumentation spec specifies **before** vs **after** the state mutation. To move a
capture point:
1. Find the `tla_trace::emit(...)` call.
2. Cut it and paste it before/after the target mutation.
3. Update the state fields if the mutation order changes what's observable.

---

## How to Rebuild and Re-run

```bash
cd artifact/autobahn
export TRACE_DIR=../../traces
export RUST_LOG=error

# Primary (Autobahn) traces
cargo test -p primary -- trace_tests:: --test-threads=1

# HotStuff traces
cargo test -p hotstuff -- hs_trace_tests:: --test-threads=1
```

Or use the top-level runner:
```bash
bash harness/run.sh
```

---

## Coverage Notes

**Covered (15 of 17 spec actions):**
`SendPrepare`, `CastPrepareVote`, `FormPrepareQC`, `SendConfirm`, `CastConfirmVote`,
`FormConfirmQC`, `SendCommit`, `ProcessCommit`, `CleanSlotPeriods`, `SendTimeout`,
`FormTC`, `ProcessTC`, `HSMakeVote`, `HSProcessBlock`, `HSCrashRecover`

**Not covered:**
- `ByzEquivocatePrepare` — Byzantine-only code path; not in honest node code.
  To exercise: inject two conflicting Prepare requests from a Byzantine sender.
- `ByzSendTimeout` — Byzantine-only; no code path in the implementation.
  To exercise: manually emit in test after injecting a forged Timeout.

These two Byzantine events require `Silent` wrappers or dedicated adversary injection
tests. They are not emitted by honest node code paths.

---

## Known Quirks

1. **FormPrepareQC / FormConfirmQC state snapshot**: The state captured at QC formation
   uses `Default::default()` (all zeros) because QC aggregation runs asynchronously
   without access to the full node state. The voters list IS accurately captured.

2. **`send_consensus_req` for SendPrepare**: Only fires when the running node IS the
   leader AND is triggered via (a) TC-based view change, or (b) coverage-based new slot
   proposal. The timeout scenario (`autobahn_timeout.ndjson`) captures the TC path.

3. **`clean_slot_periods` was not awaited** in the original code — patched to add
   `.await?` so the GC function runs and emits `CleanSlotPeriods`.
