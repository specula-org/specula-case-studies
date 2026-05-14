# Instrumentation Spec — Solana Tower BFT

Mapping between TLA+ spec actions in `base.tla` / `Trace.tla` and source-code instrumentation points in the `anza-xyz/agave` codebase.

Spec output directory: `/home/ubuntu/Specula/case-studies/solana/.specula-output/spec/`
Source: `/home/ubuntu/Specula/case-studies/solana/artifact/agave/`

---

## Section 1: Trace Event Schema

### Event envelope

Every event is a single NDJSON line of the form:

```json
{
  "tag": "trace",
  "ts_ns": 1700000000000000000,
  "event": {
    "name": "<spec_action_name>",
    "nid":  "<base58-pubkey>",  // mapped to model value v1..v4 in cfg
    "slot": <Slot>,             // if applicable
    "hash": "<bank_hash_b58>",  // if applicable (mapped to model value hA/hB)
    "state": { ... },
    "msg":   { ... }            // if this is a message-handling event
  }
}
```

### Common state fields (post-action snapshot)

Captured at every event (filling in only the fields the action modifies):

| Spec variable | Trace field | Implementation getter | Notes |
|---|---|---|---|
| `tower[v].last_voted_slot` | `state.lastVotedSlot` | `Tower::last_voted_slot()` | `consensus.rs:749` |
| `tower[v].last_voted_hash` | `state.lastVotedHash` | `Tower::last_voted_slot_hash().1` | `consensus.rs:757`; mapped to model value |
| `Len(tower[v].votes)` | `state.towerVoteCount` | `tower.vote_state.votes.len()` | `consensus/tower_vote_state.rs` |
| `tower[v].root_slot` | `state.rootSlot` | `Tower::root()` | `consensus.rs:799` |
| `persistedTower[v].last_voted_slot` | `state.persistedLastVotedSlot` | re-load from `tower_storage` after store | `tower_storage.rs:205` |
| `persistedTower[v].root_slot` | `state.persistedRootSlot` | same | |
| `alive[v]` | `state.alive` | derived: `true` outside of crash hooks | |
| `panicked[v]` | `state.panicked` | derived: `false` outside of panic-hook injection | |

### Message fields

For events that handle a network message:

| Trace field | Source |
|---|---|
| `msg.source` | the vote-tx signer pubkey |
| `msg.last_slot` | `vote_tx.last_voted_slot()` |
| `msg.last_hash` | `vote_tx.hash()` |
| `msg.kind` | `"replay"` for `cluster_info::push_vote` path; `"gossip"` for the gossip-listener path (cluster_info_vote_listener) |
| `msg.tower_slots` | `vote_tx.slots()` |

### Hash + pubkey mapping

The model-checking config uses small enumerated values (`v1`, `v2`, `hA`, `hB`). The instrumentation must emit the real base58 pubkey / bank-hash strings; a side-channel mapping file (`pubkey_map.json`, `hash_map.json`) is produced by the harness preprocessor and used during the spec run to translate captured fields back into spec values.

---

## Section 2: Action-to-Code Mapping

### `RecordVote(v, slot, hash)`

| Field | Value |
|---|---|
| Code location | `core/src/consensus.rs:700` — `Tower::record_bank_vote_and_update_lockouts` |
| Trigger point | After the function returns (post-update); the in-memory tower has just been mutated. Capture before `update_last_vote_from_vote_state` is called for the FOLLOWING vote. |
| Trace event name | `"RecordVote"` |
| Fields captured | `event.nid`, `event.slot = vote_slot`, `event.hash = vote_hash`, `state.lastVotedSlot`, `state.lastVotedHash`, `state.towerVoteCount`, `state.rootSlot` |
| Notes | Family 1 step 1. Capture must be inside the same critical section as `process_next_vote_slot` to avoid racing with the voting service. |

### `PersistTower(v)`

| Field | Value |
|---|---|
| Code location | `core/src/voting_service.rs:116-122` — `tower_storage.store(saved_tower)` |
| Trigger point | After `store()` returns Ok, **before** the broadcast call. |
| Trace event name | `"PersistTower"` |
| Fields captured | `event.nid`, `state.persistedLastVotedSlot`, `state.persistedRootSlot` |
| Notes | Family 1, brief 6.1 MC-2 / MC-8: the *purpose* of this event is to record the post-store-but-pre-broadcast frame. Capture must precede broadcast. The implementation's lack of `fsync` (line 215) is not directly observable; the harness models it by allowing the captured `persistedLastVotedSlot` to regress on the next `Crash` event (via the `CrashBeforeFsync` action). |

### `BroadcastVote(v)`

| Field | Value |
|---|---|
| Code location | `core/src/voting_service.rs:156` — `cluster_info.push_vote(&tower_slots, tx);` |
| Trigger point | Immediately after `push_vote` returns. |
| Trace event name | `"BroadcastVote"` |
| Fields captured | `event.nid`, `state.lastVotedSlot`, `state.lastVotedHash` |
| Notes | The 3-step `record → persist → broadcast` window is captured as 3 distinct events so the trace spec can find a crash interleaving between any pair. |

### `ReceiveVote(receiver, m)`

| Field | Value |
|---|---|
| Code location | `core/src/cluster_info_vote_listener.rs:680` — `process_last_vote_for_optimistic_confirmation` |
| Trigger point | After `track_optimistic_confirmation_vote` returns (line 705), so the OC accumulator is updated. |
| Trace event name | `"ReceiveVote"` |
| Fields captured | `event.nid` (receiver), `event.msg.source`, `event.msg.last_slot`, `event.msg.last_hash`, `event.msg.kind` (`"replay"` if `!is_gossip_vote`, `"gossip"` if `is_gossip_vote`) |
| Notes | One event per call to `process_last_vote_for_optimistic_confirmation`. The kind distinguishes gossip vs replay because Family 2 / Family 3 invariants depend on the source. |

### `ReachOC(slot, hash)`

| Field | Value |
|---|---|
| Code location | `core/src/cluster_info_vote_listener.rs:731-751` — the `if reached_optimistic_confirmed { ... new_optimistic_confirmed_slots.push((last_vote_slot, last_vote_hash)); }` branch |
| Trigger point | Inside the `if reached_optimistic_confirmed` block, right after the `push`. |
| Trace event name | `"ReachOC"` |
| Fields captured | `event.slot`, `event.hash` |
| Notes | Family 3. The captured `(slot, hash)` is precisely the bucket whose stake crossed 2/3. Cross-hash dedup is absent at this site, so we may observe two `ReachOC` events with the same `slot` and different `hash`. |

### `RootSlot(slot, hash)`

| Field | Value |
|---|---|
| Code location | `core/src/replay_stage.rs` — `handle_new_root` (search for the function); root advancement when a tower vote becomes 32-deep |
| Trigger point | After `bank_forks.set_root(...)` returns. |
| Trace event name | `"RootSlot"` |
| Fields captured | `event.slot`, `event.hash` (the bank hash of the new root) |
| Notes | The hash is needed for `OCRollbackBounded` validation in Family 3. |

### `PurgeUnconfirmedSlot(v, slot)`

| Field | Value |
|---|---|
| Code location | `core/src/replay_stage.rs:2019` — `purge_unconfirmed_slot` |
| Trigger point | After the function returns, so `bank_forks` / `ancestors` / `descendants` / `progress` / blockstore are all cleared. |
| Trace event name | `"PurgeUnconfirmedSlot"` |
| Fields captured | `event.nid`, `event.slot` |
| Notes | Family 4. The implementation does NOT mutate the tower at this point — the tower retains a vote on `slot`. The spec's `TowerVotesAreOnExistingForks` invariant detects this. |

### `ProcessDuplicateConfirmedSignal(v, slot, hash)`

| Field | Value |
|---|---|
| Code location | `core/src/replay_stage.rs:2205` — `process_duplicate_confirmed_slots`; specifically the `for (confirmed_slot, duplicate_confirmed_hash) in new_duplicate_confirmed_slots` loop |
| Trigger point | After `duplicate_confirmed_slots.insert(confirmed_slot, duplicate_confirmed_hash)` returns. If the assertion at line 2226 fires, capture the event with `state.panicked = true` and `state.alive = false`. |
| Trace event name | `"ProcessDuplicateConfirmedSignal"` |
| Fields captured | `event.nid`, `event.slot`, `event.hash`, `state.alive`, `state.panicked` |
| Notes | Family 4, brief 6.1 MC-5. To survive the panic, wrap the assertion site with a `catch_unwind` that records the panic as a trace event before re-throwing (only in instrumented builds). |

### `CastSwitchVote(v, slot)`

| Field | Value |
|---|---|
| Code location | `core/src/consensus.rs:1276` — `Tower::check_switch_threshold` returning `SwitchProof`; followed by `record_bank_vote_and_update_lockouts` at line 700 |
| Trigger point | After the `record_bank_vote_and_update_lockouts` returns when the call was triggered by a switch decision (track via a thread-local flag set in `make_check_switch_threshold_decision` and cleared after the record). |
| Trace event name | `"CastSwitchVote"` |
| Fields captured | `event.nid`, `event.slot` (the switch_slot), `state.lastVotedSlot`, `state.lastVotedHash`, `state.towerVoteCount` |
| Notes | Family 2, brief 6.1 MC-3. Distinguishing switch votes from normal votes lets the trace spec validate `SwitchProofRequiresRealLockout` precisely. |

### `Crash(v)`

| Field | Value |
|---|---|
| Code location | (harness-injected) — instrumented build accepts a SIGUSR1 to simulate a crash without core dump; the harness records the event timestamp |
| Trigger point | Before the process exits; capture last-known good state. |
| Trace event name | `"Crash"` |
| Fields captured | `event.nid`, `state.alive = false` |
| Notes | Family 1. The harness drives this; the validator binary itself never spontaneously emits Crash events. |

### `CrashBeforeFsyncReachesDisk(v)`

| Field | Value |
|---|---|
| Code location | (harness-injected) — same hook as Crash, but the harness simulates the page-cache loss by overwriting `tower.bin` with its pre-store backup before the validator restarts |
| Trigger point | Same as Crash. |
| Trace event name | `"CrashBeforeFsync"` |
| Fields captured | `event.nid`, `state.alive = false` |
| Notes | Family 1, brief 6.1 MC-8. The harness restores `tower.bin` from a snapshot taken at the previous Persist event. This requires a copy-on-write shadow file maintained by the instrumentation. |

### `Restart(v)`

| Field | Value |
|---|---|
| Code location | `core/src/replay_stage.rs:1587` — `load_tower`; `core/src/consensus.rs:1462` — `Tower::adjust_lockouts_after_replay` |
| Trigger point | After `adjust_lockouts_after_replay` returns Ok; the tower is loaded and ready. |
| Trace event name | `"Restart"` |
| Fields captured | `event.nid`, `state.alive = true`, `state.lastVotedSlot`, `state.lastVotedHash`, `state.towerVoteCount`, `state.rootSlot` |
| Notes | Family 1. If `adjust_lockouts_after_replay` returns Err, the validator falls back to `Tower::new_from_bankforks` (`consensus.rs:1652`) and the event should capture the post-fallback tower state. |

### `AdoptOnChainTowerIfBehind(v, bankSlot)`

| Field | Value |
|---|---|
| Code location | `core/src/replay_stage.rs:4046` — `adopt_on_chain_tower_if_behind` |
| Trigger point | After the function returns. Only emit the event if the function actually mutated the tower (i.e. early-return at line 4060 is not emitted). |
| Trace event name | `"AdoptOnChainTowerIfBehind"` |
| Fields captured | `event.nid`, `event.slot = bank.slot()`, `state.lastVotedSlot` (the NEW last-voted-slot adopted from the bank), `state.lastVotedHash`, `state.towerVoteCount` |
| Notes | Family 1, brief 6.1 MC-2. The captured slot is the bank from which the vote state was adopted. Per the brief, this is the unique-to-Tower-BFT amnesia mechanism. |

---

## Section 3: Special Considerations

### Multi-thread coordination

The agave validator has several threads that touch tower-related state:

1. **ReplayStage main loop** — `core/src/replay_stage.rs:run_loop`. Emits `RecordVote`, `PurgeUnconfirmedSlot`, `ProcessDuplicateConfirmedSignal`, `AdoptOnChainTowerIfBehind`, `CastSwitchVote`, `Restart`.
2. **VotingService thread** — `core/src/voting_service.rs:handle_vote`. Emits `PersistTower`, `BroadcastVote`.
3. **ClusterInfoVoteListener thread** — `core/src/cluster_info_vote_listener.rs:track_new_votes_and_notify_confirmations`. Emits `ReceiveVote`, `ReachOC`.

Each thread's instrumentation must use a thread-safe NDJSON writer (e.g. `tracing-appender` with `RollingFileAppender` or a dedicated `mpsc::channel` to a single writer thread). The `ts_ns` field provides total ordering across threads.

For Category A (distributed) trace validation, the trace is a single linearized sequence; the harness sorts events by `ts_ns` before handing them to TLC. Concurrent events from different threads are interleaved by timestamp.

### State captured outside the critical section

Where the action is wrapped in a mutex (e.g. `Tower` is behind a `RwLock` in `ReplayStage`), the capture must happen *inside* the lock so the post-state snapshot is consistent. Failure to do so will produce trace events with stale `state.*` fields and the trace validator will report state-mismatch errors.

### Hash and pubkey enumeration

The harness preprocessor:
1. Walks the trace file, collects all unique pubkeys and bank-hashes.
2. Assigns the first N pubkeys to `v1`..`vN` (N = number of validators in the run) and the first M hashes to `hA`..`hM`.
3. Rewrites the trace in place, substituting model values.
4. Emits `pubkey_map.json` and `hash_map.json` for back-translation when reporting counterexamples.

### Bootstrap state

`TraceInit` matches `base.Init` exactly: all towers empty, no votes, no OC, no rooted slots (except genesis). If the recording starts after the validator has been running for some time, the first trace event will fail post-state validation; capture must start at validator boot.

### Fork tree

The model parameters `ParentOfSlot` and `CanonicalSlotHash` in `base.tla` define the fork tree statically. The trace harness must record the slot-lineage observed during the run and emit a `fork_tree.json` file:

```json
{
  "parents": { "1": 0, "2": 1, "3": 1 },
  "hashes":  { "1": "hA", "2": "hA", "3": "hB" }
}
```

The cfg-generation script in the harness reads this file and emits an MC cfg matching the recorded shape. The default cfg (`Trace.cfg`) assumes the minimal 2-fork shape (`{1: 0, 2: 1, 3: 1}` with hashes `{hA, hA, hB}`).

### Events the trace deliberately does NOT capture

| Spec action | Why not |
|---|---|
| Byzantine actions (`ByzVoteOnBothForks`, `ByzGossipFakeLatestFrozenVote`, etc.) | These exist only for MC bug-hunting; real implementation traces will not contain them. |
| `DropMessage` | The implementation does not log message drops; the silent action `SilentDropMessage` in `Trace.tla` handles this. |

### Optimization: skip uninteresting state fields

For events that do NOT modify a given state field, omit it from the post-state snapshot. The trace spec's `ValidatePostState*` helpers only check the fields the action's modifies. Capturing extra fields wastes bandwidth and slows down validation.

### `panicked` flag

For events whose post-state has `panicked = true`, the validator process has been forced into the panic branch by the instrumentation; the trace event is the last event from that validator until a `Restart` event arrives. This is the case for `ProcessDuplicateConfirmedSignal` when the assertion at `replay_stage.rs:2226` fires.

### Refresh vs push votes

`core/src/voting_service.rs` distinguishes `VoteOp::PushVote` (initial broadcast) from `VoteOp::RefreshVote` (re-broadcast after lack of inclusion). Only `PushVote` should emit `BroadcastVote` events; refresh re-broadcasts are not modeled in the spec (the brief explicitly excludes refresh-vote logic).

---

## Appendix: Trace file location convention

`Trace.tla` reads from `../traces/trace.ndjson` by default (sibling to `spec/`), overridable via the `JSON` IOEnv variable:

```bash
java -DJSON=../traces/my_run.ndjson -cp .../tla2tools.jar tlc2.TLC \
    -config Trace.cfg Trace.tla
```

Per-run trace files should live at `case-studies/solana/.specula-output/traces/`. The directory is created by the harness, not by the spec generation pipeline.
