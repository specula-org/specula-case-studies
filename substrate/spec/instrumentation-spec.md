# Instrumentation Spec: Substrate GRANDPA

Maps TLA+ spec actions to source code locations for trace collection.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node": "<server_id>",
  "timestamp": "<unix_ms>",
  "state": {
    "finalizedBlock": <block_number>,
    "setId": <set_id>,
    "currentRound": <round_number>,
    "bestBlock": <block_number>
  },
  ...action-specific fields...
}
```

### State Fields (captured at every event)

| Implementation Field | TLA+ Variable | Source |
|---------------------|---------------|--------|
| `client.info().finalized_number` | `finalizedBlock[node]` | environment.rs:1375 |
| `authority_set.set_id()` | `setId[node]` | authorities.rs:152 |
| `voter_set_state` current round | `currentRound[node]` | environment.rs:370-381 |
| `client.info().best_number` | `bestBlock[node]` | environment.rs:1234 |

## Section 2: Action-to-Code Mapping

### ProduceBlock

| Field | Value |
|-------|-------|
| **Spec action** | `ProduceBlock(s, parent, newBlock)` |
| **Code location** | `client/consensus/grandpa/src/import.rs:522-578` |
| **Trigger point** | After `inner.import_block(block).await` returns `ImportResult::Imported` |
| **Event name** | `ProduceBlock` |
| **Fields** | `node`, `block` (block number), `parent` (parent number) |
| **Notes** | Only emit for new blocks (`BlockStatus::Unknown`), not re-imports |

### AddStandardChange

| Field | Value |
|-------|-------|
| **Spec action** | `AddStandardChange(s, block, delay, newAuth)` |
| **Code location 1** | `client/consensus/grandpa/src/import.rs:331-340` — `add_pending_change` call inside `make_authorities_changes` |
| **Code location 2** | `client/consensus/grandpa/src/authorities.rs:304-334` — `add_standard_change` |
| **Trigger point** | After `guard.as_mut().add_pending_change(change, ...)` succeeds, when `change.delay_kind == DelayKind::Finalized` |
| **Event name** | `AddStandardChange` |
| **Fields** | `node`, `block` (canon_height), `delay`, `newAuthorities` (serialized authority list) |
| **Notes** | Filter by `DelayKind::Finalized`. The `delay` is `change.delay` and `block` is `change.canon_height`. |

### AddForcedChange

| Field | Value |
|-------|-------|
| **Spec action** | `AddForcedChange(s, block, delay, newAuth, medFin)` |
| **Code location 1** | `client/consensus/grandpa/src/import.rs:331-340` — same call site as standard |
| **Code location 2** | `client/consensus/grandpa/src/authorities.rs:336-380` — `add_forced_change` |
| **Trigger point** | After `guard.as_mut().add_pending_change(change, ...)` succeeds, when `change.delay_kind == DelayKind::Best { median_last_finalized }` |
| **Event name** | `AddForcedChange` |
| **Fields** | `node`, `block` (canon_height), `delay`, `newAuthorities`, `medianFinalized` |
| **Notes** | Extract `median_last_finalized` from `DelayKind::Best { ref median_last_finalized }` |

### ApplyStandardChange

| Field | Value |
|-------|-------|
| **Spec action** | `ApplyStandardChange(s)` |
| **Code location** | `client/consensus/grandpa/src/authorities.rs:541-602` — `apply_standard_changes` |
| **Trigger point** | After `apply_standard_changes` returns `Status { changed: true, new_set_block: Some(...) }` |
| **Event name** | `ApplyStandardChange` |
| **Fields** | `node`, `state` (full state snapshot after change) |
| **Notes** | Called from `environment.rs:1394-1402` inside `finalize_block`. The state snapshot should capture the new `set_id` and `current_authorities` after the change. |

### ApplyForcedChange

| Field | Value |
|-------|-------|
| **Spec action** | `ApplyForcedChange(s)` |
| **Code location** | `client/consensus/grandpa/src/authorities.rs:447-529` — `apply_forced_changes` |
| **Trigger point** | After `apply_forced_changes` returns `Ok(Some((median, new_set)))` |
| **Event name** | `ApplyForcedChange` |
| **Fields** | `node`, `state` (full state snapshot after change) |
| **Notes** | Called from `import.rs:345-358`. The new set is assigned via `std::mem::replace` at `import.rs:390`. |

### FinalizeBlock (atomic path)

| Field | Value |
|-------|-------|
| **Spec action** | `FinalizeBlock(s, block)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:1354-1543` — `finalize_block` |
| **Trigger point** | After `finalize_block` completes successfully (returns `Ok(())` or `Err(VoterCommand)`) |
| **Event name** | `FinalizeBlock` |
| **Fields** | `node`, `block` (finalized block number), `state` (post-finalization state) |
| **Notes** | If modeling atomic finalization (without sub-step races), emit a single event. If modeling sub-steps, use the four sub-step events below instead. |

### AcquireFinalizationLock

| Field | Value |
|-------|-------|
| **Spec action** | `AcquireFinalizationLock(s, block, path)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:1370-1373` — `authority_set.inner()` call |
| **Trigger point** | Immediately after `let mut authority_set = authority_set.inner()` |
| **Event name** | `AcquireFinalizationLock` |
| **Fields** | `node`, `block` (block being finalized), `path` ("gossip" if from `Environment::finalize_block` trait method, "sync" if from `import_justification`) |
| **Notes** | `path` distinguishes the two callers: `Environment::finalize_block` (line 1095, gossip-based) vs `import_justification` (import.rs:769, sync-based) |

### WriteToDisk

| Field | Value |
|-------|-------|
| **Spec action** | `WriteToDisk(s)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:1451-1530` — `apply_finality` + `update_authority_set` |
| **Trigger point** | After `client.apply_finality(...)` at line 1454 completes successfully |
| **Event name** | `WriteToDisk` |
| **Fields** | `node`, `state` (post-write state with updated `finalizedBlock`) |
| **Notes** | This is the non-atomic persistence point. Finality is written but authority set may not be yet (line 1514-1530). |

### ReleaseFinalizationLock

| Field | Value |
|-------|-------|
| **Spec action** | `ReleaseFinalizationLock(s)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:1543` — end of `finalize_block` function (lock drops when `authority_set` goes out of scope) |
| **Trigger point** | At the end of `finalize_block`, just before returning |
| **Event name** | `ReleaseFinalizationLock` |
| **Fields** | `node` |
| **Notes** | Lock is released implicitly by Rust's RAII. Instrument at function exit point. |

### Propose

| Field | Value |
|-------|-------|
| **Spec action** | `Propose(s, r, block)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:797-838` — `proposed()` |
| **Trigger point** | After `write_voter_set_state` at line 832 succeeds |
| **Event name** | `Propose` |
| **Fields** | `node`, `round`, `block` (proposal target block number), `state` |
| **Notes** | Check `can_propose()` (line 814) returns true before emitting. If false, the vote is from a prior run and should not be traced. |

### Prevote

| Field | Value |
|-------|-------|
| **Spec action** | `Prevote(s, r, block)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:840-901` — `prevoted()` |
| **Trigger point** | After `write_voter_set_state` succeeds inside `update_voter_set_state` |
| **Event name** | `Prevote` |
| **Fields** | `node`, `round`, `block` (prevote target block number), `state` |
| **Notes** | Check `can_prevote()` (line 871) returns true. The `block` is `prevote.target_number`. |

### Precommit

| Field | Value |
|-------|-------|
| **Spec action** | `Precommit(s, r, block)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:903-974` — `precommitted()` |
| **Trigger point** | After `write_voter_set_state` succeeds inside `update_voter_set_state` |
| **Event name** | `Precommit` |
| **Fields** | `node`, `round`, `block` (precommit target block number), `state` |
| **Notes** | Check `can_precommit()` (line 942) returns true. Safety check at line 948: must have previously prevoted. |

### CompleteRound

| Field | Value |
|-------|-------|
| **Spec action** | `CompleteRound(s, r)` |
| **Code location** | `client/consensus/grandpa/src/environment.rs:976-1036` — `completed()` |
| **Trigger point** | After `write_voter_set_state` succeeds |
| **Event name** | `CompleteRound` |
| **Fields** | `node`, `round`, `state` (with `currentRound = round + 1`) |
| **Notes** | The round is removed from `current_rounds` and `round + 1` is inserted (line 1023). |

### ByzantinePrevote / ByzantinePrecommit

| Field | Value |
|-------|-------|
| **Spec action** | `ByzantinePrevote(s, r, block)` / `ByzantinePrecommit(s, r, block)` |
| **Code location** | N/A — these are detected from received messages, not from local actions |
| **Trigger point** | When a received vote is identified as equivocating (duplicate voter with different target) |
| **Event name** | `ByzantinePrevote` / `ByzantinePrecommit` |
| **Fields** | `node` (observer), `round`, `block` (equivocating target), `voter` (equivocator ID) |
| **Notes** | Equivocation detection happens in the finality-grandpa crate's `Round` type. Instrument the point where an equivocation is first detected and recorded. |

### Crash / Recover

| Field | Value |
|-------|-------|
| **Spec action** | `Crash(s)` / `Recover(s)` |
| **Code location** | `client/consensus/grandpa/src/lib.rs:986-1023` — `rebuild_voter` on recovery |
| **Trigger point** | Crash: test harness injects crash. Recover: when `rebuild_voter` is called after restart. |
| **Event name** | `Crash` / `Recover` |
| **Fields** | `node`, `state` (for Recover: post-recovery state from persisted data) |
| **Notes** | Crash events are typically injected by the test harness. Recovery is detected when the voter lifecycle restarts. |

## Section 3: Special Considerations

### 3.1 Non-Atomic Persistence

The `finalize_block` function writes state in multiple non-atomic steps:
1. `apply_finality` (environment.rs:1454) — writes finalized block
2. `update_best_justification` (environment.rs:1474-1476) — writes justification
3. `update_authority_set` (environment.rs:1514-1530) — writes authority set

A crash between steps 1 and 3 leaves the node in a state where finality is advanced but the authority set is not updated. The `WriteToDisk` event should be emitted after step 1, capturing the intermediate state.

### 3.2 Authority Set Lock Semantics

The authority set lock (`SharedAuthoritySet::inner()`) uses `parking_lot::RwLock`. The lock is:
- Acquired exclusively in `finalize_block` (environment.rs:1370-1373)
- Acquired exclusively in `make_authorities_changes` (import.rs:323)
- Released before `inner.import_block()` (import.rs:420 — `release_mutex()`)

The `AcquireFinalizationLock` and `ReleaseFinalizationLock` events bracket the critical section. The lock release inside `make_authorities_changes` is implicit and not separately traced (it happens as part of the `make_authorities_changes` return).

### 3.3 HasVoted State and Crash Recovery

The `HasVoted` enum (environment.rs:259-319) is persisted via `write_voter_set_state` on every vote. On recovery, the voter checks `has_voted(round)` (environment.rs:370-381) and only honors it if the `AuthorityId` matches (environment.rs:735-743). The `Recover` event should capture the restored `hasVoted` state from `aux_schema`.

### 3.4 Concurrent Finalization Paths

Two independent code paths can trigger finalization:
1. **Gossip path**: `Environment::finalize_block` (environment.rs:1095-1113) — called by the voter future when a commit is observed
2. **Sync path**: `import_justification` (import.rs:769-843) — called during block import when a justification is received

Both paths call the same `finalize_block` free function (environment.rs:1354-1543) but are invoked from different async tasks. The `path` field in `AcquireFinalizationLock` distinguishes them.

### 3.5 Server ID Mapping

Implementation uses `PeerId` / `AuthorityId` which need to be mapped to TLA+ server identifiers (`s1`, `s2`, etc.). The mapping should be established at trace start based on the initial authority set, and should remain stable across authority set changes (a server keeps its ID even if it leaves/joins the authority set).

### 3.6 Block Number Mapping

The implementation uses generic block number types (`NumberFor<Block>`). For trace purposes, these should be serialized as plain integers. The `blockTree` in the spec is indexed by block number with `blockTree[b] = parent_number`. The trace should include parent block numbers for `ProduceBlock` events.
