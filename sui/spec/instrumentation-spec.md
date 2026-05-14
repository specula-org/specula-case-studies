# Instrumentation Spec — Sui Mysticeti Consensus

This document maps each TLA+ spec action in `base.tla` to the Rust source
code locations where instrumentation hooks must be added to produce
trace events compatible with `Trace.tla`.

Source crate: `consensus/core/src/`. Trace tag: `"trace"`. Format: NDJSON,
one event per line.

---

## Section 1: Trace Event Schema

### Event envelope

Every trace line is a JSON object:

```json
{
  "tag": "trace",
  "event": {
    "name":  "<spec action name>",
    "nid":   "<validator ID, e.g. s1>",
    "state": { ...post-action state snapshot... },
    ...event-specific fields...
  }
}
```

### State fields (captured at every event, post-action)

| Trace field            | Implementation getter                                     | TLA+ variable                |
|------------------------|-----------------------------------------------------------|------------------------------|
| `clockRound`           | `dag_state.threshold_clock_round()` (`dag_state.rs:1147`) | `clockRound[i]`              |
| `gcRound`              | `dag_state.gc_round()` (`dag_state.rs:1175-1186`)         | `gcRound[i]`                 |
| `lastProposedRound`    | `dag_state.get_last_proposed_block().round()`             | `lastProposedRound[i]`       |
| `lastKnownProposed`    | `core.last_known_proposed_round` (`core.rs`)              | `lastKnownProposed[i]`       |
| `signedHistorySize`    | `Cardinality(signedHistory[i])` — needs shadow map        | `Cardinality(signedHistory[i])` |
| `commitSeqLen`         | `dag_state.last_commit_index()`                           | `Len(committedSeq[i])`       |
| `certifiedCommitRound` | `core.last_certified_commit_round` (custom shadow)        | `certifiedCommitRound[i]`    |
| `crashed`              | (instrumentation flag, false in normal operation)         | `crashed[i]`                 |

### Block fields (event-specific)

```json
"block": {
  "author":    "<authority hostname>",
  "round":     <u32>,
  "digest":    <u64>,        // first 8 bytes of BlockDigest
  "ancestors": [{ "author": ..., "round": ..., "digest": ... }, ...],
  "timestamp": <u64>,
  "commitVotes": [{ "index": <u64>, "digest": <u64> }, ...]
}
```

Source: `consensus_types::block::Block`, accessed via `block.rs` `BlockAPI`
trait (`author()`, `round()`, `digest()`, `ancestors()`, `timestamp_ms()`,
`commit_votes()`).

### Slot fields

```json
"slot": { "author": "<authority>", "round": <u32> }
```

Source: `block::Slot` (`block.rs` Slot::new).

### BlockRef fields

```json
"<field>": { "author": "...", "round": ..., "digest": ... }
```

Source: `block::BlockRef` (`block.rs` BlockRef::new).

---

## Section 2: Action-to-Code Mapping

### `HonestPropose`

| Field | Value |
|---|---|
| **Spec action** | `HonestPropose(s)` (base.tla:306) |
| **Code location** | `proposer.rs:367-411` (`ValidatorProposer::try_new_block`) |
| **Trigger point** | After `core.add_blocks(vec![extended_block.clone()])` succeeds — i.e., after the new block is in `dag_state` and has been signed. Hook at end of `core.rs::try_new_block` once the block is broadcast. |
| **Event name** | `"HonestPropose"` |
| **Fields** | `block` (the new block, full schema), `state` (clockRound, gcRound, lastProposedRound, signedHistorySize) |
| **Notes** | Distinguish from `ForcePropose` by the `force` flag on `try_new_block(force: bool)`. If `force = true` AND the smart-select wait was bypassed, emit `ForcePropose` instead. |

### `ByzPropose`

| Field | Value |
|---|---|
| **Spec action** | `ByzPropose(s, r, d)` (base.tla:353) |
| **Code location** | Test-harness only. Hook in test fixtures that simulate Byzantine validators (e.g., `core_tests.rs`, `base_committer_tests.rs`). |
| **Trigger point** | Before `dag_state.accept_block(byzantine_block)` in tests/fault-injection harnesses. |
| **Event name** | `"ByzPropose"` |
| **Fields** | `block` (the Byzantine block) |
| **Notes** | This event is only generated in adversarial test runs — production validators don't emit it. The harness needs to know which authority indices map to Byzantine validators. |

### `DeliverBlock`

| Field | Value |
|---|---|
| **Spec action** | `DeliverBlock(s, b)` (base.tla:391) |
| **Code location** | `block_manager.rs:309-355` (`try_accept_one_block`) — at the point where the block transitions from "suspended" to "accepted". |
| **Trigger point** | After `dag_state.accept_block(block.clone())` returns successfully. Specifically at `block_manager.rs::try_accept_blocks` after the block is moved out of `suspended_blocks` and into `dag_state`. |
| **Event name** | `"DeliverBlock"` |
| **Fields** | `block` (the accepted block), `state` (clockRound after threshold-clock update, gcRound) |
| **Notes** | Skip if the block is the validator's own block (already captured by `HonestPropose`). The `b \notin dag[s]` guard in the spec corresponds to `block_manager`'s check that suppresses duplicate accepts. |

### `TryDirectDecide`

| Field | Value |
|---|---|
| **Spec action** | `TryDirectDecide(s, slot)` (base.tla:463) |
| **Code location** | `base_committer.rs:86-117` (`BaseCommitter::try_direct_decide`) |
| **Trigger point** | At each `return` statement in `try_direct_decide` (lines 91, 116) — capture the `LeaderStatus` outcome. |
| **Event name** | `"TryDirectDecide"` |
| **Fields** | `slot` ({author, round} of leader_slot), `outcome` ("Commit" | "Skip" | "Undecided"), `state` (gcRound, clockRound) |
| **Notes** | When `outcome = "Commit"`, also emit a `commitRef` field with the chosen leader block reference. Multi-block-with-support case (lines 108-112) panics — emit a separate diagnostic event before the panic. |

### `TryIndirectDecide`

| Field | Value |
|---|---|
| **Spec action** | `TryIndirectDecide(s, slot, anchorRef)` (base.tla:498) |
| **Code location** | `base_committer.rs:122-145` (`try_indirect_decide`) + `:284-334` (`decide_leader_from_anchor`) |
| **Trigger point** | At the end of `decide_leader_from_anchor` after the `LeaderStatus` is determined (line 334). |
| **Event name** | `"TryIndirectDecide"` |
| **Fields** | `slot` (target leader_slot), `anchor` (the BlockRef of the committed anchor leader), `outcome`, `state` (gcRound, clockRound) |
| **Notes** | The anchor traversal at `dag_state.rs:559-578` (`ancestors_at_round`) panics on missing intermediate blocks (Family 3); this would be a separate `DecideRecursionPanic` diagnostic event if instrumented for panic-recovery. |

### `Linearize`

| Field | Value |
|---|---|
| **Spec action** | `Linearize(s, leaderRef)` (base.tla:555) |
| **Code location** | `linearizer.rs:65-120` (`collect_sub_dag_and_commit`) + `:156-218` (`linearize_sub_dag`) |
| **Trigger point** | After `dag_state.add_commit(commit.clone())` completes (linearizer.rs:237 inside `handle_commit`). |
| **Event name** | `"Linearize"` |
| **Fields** | `leader` (BlockRef of the committed leader), `state` (commitSeqLen = `last_commit_index` after add_commit, gcRound after update) |
| **Notes** | Optionally include `subDagBlockCount` = `sub_dag.blocks.len()` for sanity checks, and `subDagDigest` if a content hash is computed; this is what MC1 is checking for divergence. |

### `Crash`

| Field | Value |
|---|---|
| **Spec action** | `Crash(s)` (base.tla:640) |
| **Code location** | Test-harness only. Hook in simtest fault-injection points and in `authority_node.rs` shutdown/restart paths. |
| **Trigger point** | Before `authority_node.stop()` or before any test `kill -9` simulation. |
| **Event name** | `"Crash"` |
| **Fields** | (only `nid`, no state — by definition no post-state) |
| **Notes** | This is an adversarial fault — production systems don't emit it. The instrumentation harness records it to drive trace replay through crash-recovery scenarios. |

### `RecoverAmnesia`

| Field | Value |
|---|---|
| **Spec action** | `RecoverAmnesia(s)` (base.tla:680) |
| **Code location** | `synchronizer.rs:800-921` (`start_fetch_own_last_block_task`) |
| **Trigger point** | After `core_dispatcher.set_last_known_proposed_round(highest_round)` returns (line 919). |
| **Event name** | `"RecoverAmnesia"` |
| **Fields** | `state.lastKnownProposed` (= the value just set), optionally `responderCount` and `responderStake` for debugging the f+1 vs 2f+1 question |
| **Notes** | `crashed[i]` flips to FALSE here. The instrumentation must be conditional on the validator having previously been `Crash`-ed in the harness (otherwise normal startup would emit spurious recovery events). |

### `AddCertifiedCommit`

| Field | Value |
|---|---|
| **Spec action** | `AddCertifiedCommit(s, r)` (base.tla:711) |
| **Code location** | `commit_syncer.rs` — inside `Core::add_certified_commits` (search `core.rs` for `add_certified_commits`). |
| **Trigger point** | After certified commits are absorbed and `clockRound` has caught up. |
| **Event name** | `"AddCertifiedCommit"` |
| **Fields** | `round` (highest commit round absorbed), `state.clockRound`, `state.certifiedCommitRound` |
| **Notes** | Distinguish from the round-by-round commit path: this event fires only on peer-pushed certified commits, not local `try_decide`. |

### `ForcePropose`

| Field | Value |
|---|---|
| **Spec action** | `ForcePropose(s)` (base.tla:734) |
| **Code location** | `leader_timeout.rs` (`LeaderTimeout::run`) → `core.rs::try_propose(force=true)` → `proposer.rs::try_new_block(force=true)` → `smart_ancestors_to_propose(_, smart_select=false)` |
| **Trigger point** | Same as `HonestPropose`, but capture the `force = true` flag. If `force = true`, emit `ForcePropose` instead of `HonestPropose`. |
| **Event name** | `"ForcePropose"` |
| **Fields** | `block` (full schema), `state` (clockRound, gcRound, lastProposedRound) |
| **Notes** | The assertion at `proposer.rs:352-354` is the bug surface for MC4. If the assertion is reached but would fail, emit a `ForceProposeAssertViolated` diagnostic event before panicking. |

---

## Section 3: Special Considerations

### State-field shadow maps

Several TLA+ variables have no direct getter in the production code:

- **`signedHistory[s]`** — the implementation persists signed blocks in
  RocksDB (`storage/rocksdb_store.rs`) but does not maintain a lookup
  by `(round, digest)`. To populate `signedHistorySize`, add a
  `signed_round_digests: BTreeSet<(Round, BlockDigest)>` shadow field
  to `Core` and update it at every `sign_block` call. Persist on Crash
  (write to a separate column family `consensus_signed_blocks`).
- **`certifiedCommitRound[s]`** — not stored. Add a counter to `Core`
  that updates on every `add_certified_commits` call.
- **`decided[s][slot]`** — partially in `last_decided_leader` but per-slot
  outcomes are not retained. To reconstruct, instrument
  `try_direct_decide` and `try_indirect_decide` to emit each outcome
  rather than only the latest.

### Concurrent threads

Mysticeti runs many tokio tasks; only the **Core thread** mutates
`DagState` via the mpsc queue (`core_thread.rs:105-138`). All instrumentation
hooks should serialize through Core to keep event ordering linear in the
trace file. Network handlers (synchronizer, commit_syncer, round_prober)
must enqueue trace records into a tracing channel rather than writing
directly to the trace file, to avoid out-of-order events.

### Bootstrap state

Production validators start by replaying RocksDB on boot; this looks
like many `DeliverBlock` events at startup. The trace harness should
mark these with a `bootstrap: true` flag (or skip them entirely) so
trace replay doesn't try to validate state transitions that match the
post-bootstrap snapshot, not the spec's `Init`.

### Serialization quirks

- `BlockDigest` is 32 bytes; for trace JSON we truncate to 8 bytes
  (matching the `BlockRef::hash` impl). Spec uses small integers in
  `Digest`. Map: hash trace digests to the spec's `1..MaxDigest` via the
  test harness's known equivocation-pair table.
- `BlockTimestampMs` is `u64`; the spec uses `0..MaxTimestamp`. The
  trace preprocessor should compress real timestamps to small integers
  preserving order (rdtsc-style compression).
- Empty sets serialize as `[]` (JSON arrays); deserialize via
  `Trace.tla::TraceBlock` which rebuilds set semantics from sequences.

### Byzantine vs honest distinction

The base spec models Byzantine validators with a separate `ByzPropose`
action. Real Sui has no Byzantine validators in production traces —
`ByzPropose` events are only emitted in **simtest** fault-injection
runs that explicitly simulate Byzantine behavior. Trace files from
production validators will only contain honest events; bug-hunting
traces from simtest will contain both.

### Slot vs BlockRef

The implementation distinguishes:
- `Slot = (round, author)` — `block.rs::Slot`
- `BlockRef = (round, author, digest)` — `block.rs::BlockRef`

In trace events:
- `slot` fields use `{author, round}`
- `leader`, `anchor`, `block` fields use `{author, round, digest}`

This is the asymmetry that issue #24498 surfaced — the trace must
preserve it, otherwise equivocation-handling bugs become invisible in
trace replay.
