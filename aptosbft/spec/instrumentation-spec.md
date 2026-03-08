# Instrumentation Spec: Aptos BFT (2-chain HotStuff / Jolteon)

Mapping between TLA+ spec actions and source code locations for trace collection.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "timestamp": "<unix_ms>",
  "event": {
    "name": "<spec_action_name>",
    "nid": "<server_id>",
    "epoch": <epoch_number>,
    "round": <round_number>,
    "state": { ... },
    "msg": { ... }
  }
}
```

### State Fields (captured at every event)

| Implementation Field | TLA+ Variable | Access Pattern |
|---------------------|---------------|----------------|
| `safety_data.last_voted_round` | `lastVotedRound` | `persistent_storage.safety_data()?.last_voted_round` |
| `safety_data.preferred_round` | `preferredRound` | `persistent_storage.safety_data()?.preferred_round` |
| `safety_data.one_chain_round` | `oneChainRound` | `persistent_storage.safety_data()?.one_chain_round` |
| `safety_data.highest_timeout_round` | `highestTimeoutRound` | `persistent_storage.safety_data()?.highest_timeout_round` |
| `safety_data.epoch` | `currentEpoch` | `persistent_storage.safety_data()?.epoch` |
| `round_state.current_round()` | `currentRound` | `self.round_state.current_round()` |
| `sync_info().highest_quorum_cert().certified_block().round()` | `highestQCRound` | `self.block_store.sync_info().highest_quorum_cert().certified_block().round()` |
| `sync_info().highest_ordered_round()` | `highestOrderedRound` | `self.block_store.sync_info().highest_ordered_round()` |
| `sync_info().highest_2chain_timeout_round()` | `highestTCRound` | `self.block_store.sync_info().highest_2chain_timeout_round()` |
| `block_store.commit_root().round()` | `committedRound` | `self.block_store.commit_root().round()` |

### Message Fields (event-specific)

| Field | Description |
|-------|-------------|
| `msg.source` | Message author (`m.author()` or `vote.author()`) |
| `msg.round` | Message round |
| `msg.epoch` | Message epoch |
| `msg.value` | Block ID / proposal hash (hex string) |

## Section 2: Action-to-Code Mapping

### 1. Propose

| Field | Value |
|-------|-------|
| **Spec action** | `Propose` |
| **Code location** | `round_manager.rs:532-600` (`generate_and_send_proposal`) |
| **Trigger point** | After `safety_rules.sign_proposal()` succeeds, before `network.broadcast_proposal()` |
| **Trace event name** | `"Propose"` |
| **Fields** | State snapshot + `proposalValue` (block ID of proposed block) |
| **Notes** | Proposal generation runs on a separate tokio task (line 511). Instrument inside `generate_and_send_proposal`. |

### 2. ReceiveProposal

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveProposal` |
| **Code location** | `round_manager.rs:1127-1307` (`process_proposal`) |
| **Trigger point** | After `block_store.insert_block()` at line 1277-1280, before backpressure check |
| **Trace event name** | `"ReceiveProposal"` |
| **Fields** | State snapshot + `msg.source` (proposal author), `msg.round`, `msg.value` |
| **Notes** | Must emit AFTER the block is stored. Self-proposals (where source == nid) should also emit for completeness. |

### 3. CastVote

| Field | Value |
|-------|-------|
| **Spec action** | `CastVote` |
| **Code location** | `round_manager.rs:1521-1565` (`vote_block`) → calls `safety_rules_2chain.rs:53-95` (`guarded_construct_and_sign_vote_two_chain`) |
| **Trigger point** | After `safety_rules.construct_and_sign_vote_two_chain()` succeeds (line 1541-1544), after `storage.save_vote()` (line 1560-1562) |
| **Trace event name** | `"CastVote"` |
| **Fields** | Full state snapshot (lastVotedRound, preferredRound, oneChainRound, highestTimeoutRound) |
| **Notes** | This is the primary voting path with full safety guards. Emit AFTER persist to capture the persisted state. The vote includes self-vote. |

### 4. ReceiveVote

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveVote` |
| **Code location** | `round_manager.rs:1743-1793` (`process_vote`) |
| **Trigger point** | After `round_state.insert_vote()` at line 1788-1790 |
| **Trace event name** | `"ReceiveVote"` |
| **Fields** | State snapshot + `msg.source` (voter), `msg.round` |
| **Notes** | Self-votes are delivered locally after CastVote. For self-votes (source == nid), the trace spec handles as no-op. |

### 5. FormQC

| Field | Value |
|-------|-------|
| **Spec action** | `FormQC` |
| **Code location** | `round_manager.rs:1802` (`VoteReceptionResult::NewQuorumCertificate`) → `round_manager.rs:1946-1958` (`new_qc_aggregated`) |
| **Trigger point** | After `block_store.insert_quorum_cert()` and `process_certificates()` at line 1956 |
| **Trace event name** | `"FormQC"` |
| **Fields** | State snapshot + cert state (highestQCRound, highestOrderedRound) + `round` of QC |
| **Notes** | FormQC triggers order vote broadcast (line 1816-1836). Emit FormQC BEFORE the order vote broadcast. |

### 6. CastOrderVote

| Field | Value |
|-------|-------|
| **Spec action** | `CastOrderVote` |
| **Code location** | `round_manager.rs:1674-1710` (`broadcast_order_vote`) → calls `safety_rules_2chain.rs:97-119` (`guarded_construct_and_sign_order_vote`) |
| **Trigger point** | After `create_order_vote()` succeeds (line 1681-1683), before `network.broadcast_order_vote()` (line 1701) |
| **Trace event name** | `"CastOrderVote"` |
| **Fields** | Full state snapshot (Family 2: verify oneChainRound, preferredRound updated but NOT lastVotedRound) |
| **Notes** | Order votes have independent safety checks from regular votes. The key verification point is that `lastVotedRound` is NOT updated. |

### 7. ReceiveOrderVote

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveOrderVote` |
| **Code location** | `round_manager.rs:1567-1645` (`process_order_vote_msg`) |
| **Trigger point** | After `pending_order_votes.insert_order_vote()` at line 1607-1617 |
| **Trace event name** | `"ReceiveOrderVote"` |
| **Fields** | State snapshot + `msg.source` (voter), `msg.round` |
| **Notes** | Family 2: Does NOT call `ensure_round_and_sync_up`. Uses 100-round window check (line 1592-1593). QC verification skipped for 2nd+ votes (line 1598). |

### 8. FormOrderingCert

| Field | Value |
|-------|-------|
| **Spec action** | `FormOrderingCert` |
| **Code location** | `round_manager.rs:1918-1944` (`process_order_vote_reception_result`) → `round_manager.rs:2007-2024` (`new_ordered_cert`) |
| **Trigger point** | After `block_store.insert_ordered_cert()` at line 2019 |
| **Trace event name** | `"FormOrderingCert"` |
| **Fields** | State snapshot + cert state (highestOrderedRound) + `round` |
| **Notes** | Family 2: This is the Jolteon-specific ordering certificate formation from 2f+1 order votes. |

### 9. SignTimeout

| Field | Value |
|-------|-------|
| **Spec action** | `SignTimeout` |
| **Code location** | `round_manager.rs:1009-1106` (`process_local_timeout`) → calls `safety_rules_2chain.rs:19-51` (`guarded_sign_timeout_with_qc`) |
| **Trigger point** | After `safety_rules.sign_timeout_with_qc()` succeeds (line 1033-1037 or 1084-1091), before broadcast |
| **Trace event name** | `"SignTimeout"` |
| **Fields** | Full state snapshot (lastVotedRound, highestTimeoutRound both potentially updated) |
| **Notes** | Two code paths: (1) `enable_round_timeout_msg=true` (line 1021-1059): creates RoundTimeout, broadcasts via `broadcast_round_timeout`. (2) `enable_round_timeout_msg=false` (line 1061-1105): creates timeout vote, broadcasts via `broadcast_timeout_vote`. Both call `sign_timeout_with_qc`. Emit from both paths. |

### 10. ReceiveTimeout

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveTimeout` |
| **Code location** | `round_manager.rs:1876-1916` (`process_round_timeout_msg`) → `round_manager.rs:1902-1916` (`process_round_timeout`) |
| **Trigger point** | After `round_state.insert_round_timeout()` at line 1911-1913 |
| **Trace event name** | `"ReceiveTimeout"` |
| **Fields** | State snapshot + `msg.source` (timeout author), `msg.round` |
| **Notes** | Uses `ensure_round_and_sync_up` (line 1886-1893), unlike order votes. |

### 11. FormTC

| Field | Value |
|-------|-------|
| **Spec action** | `FormTC` |
| **Code location** | `round_manager.rs:1861` (`VoteReceptionResult::New2ChainTimeoutCertificate`) → `round_manager.rs:2026-2036` (`new_2chain_tc_aggregated`) |
| **Trigger point** | After `block_store.insert_2chain_timeout_certificate()` and `process_certificates()` |
| **Trace event name** | `"FormTC"` |
| **Fields** | State snapshot + cert state (highestTCRound) + `round` |
| **Notes** | TC formation advances the current round. |

### 12. SignCommitVote

| Field | Value |
|-------|-------|
| **Spec action** | `SignCommitVote` |
| **Code location** | `safety_rules.rs:372-418` (`guarded_sign_commit_vote`) called from `buffer_manager.rs` signing phase |
| **Trigger point** | After `safety_rules.sign_commit_vote()` succeeds, in the signing phase of `buffer_manager.rs` |
| **Trace event name** | `"SignCommitVote"` |
| **Fields** | State snapshot + `round` of the block being committed |
| **Notes** | Family 1: The commit vote path has TODO markers for missing guards (line 412-413). Instrument captures state to detect the missing round-monotonicity check. |

### 13. ReceiveCommitVote

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveCommitVote` |
| **Code location** | `buffer_manager.rs:736-800` (`process_commit_message`) |
| **Trigger point** | After commit vote is added to the buffer item's partial_commit_proof |
| **Trace event name** | `"ReceiveCommitVote"` |
| **Fields** | State snapshot + `msg.source` (voter), `msg.round` |
| **Notes** | Family 3: Commit votes are processed in the pipeline's BufferManager, not the RoundManager. |

### 14. ExecuteBlock

| Field | Value |
|-------|-------|
| **Spec action** | `ExecuteBlock` |
| **Code location** | `buffer_manager.rs` execution_wait_phase → `buffer_item.rs:122-187` (`advance_to_executed`) |
| **Trigger point** | After execution result is received and buffer item transitions from Ordered to Executed |
| **Trace event name** | `"ExecuteBlock"` |
| **Fields** | State snapshot + `round` + pipeline phase |
| **Notes** | Family 3: Execution is async; the event fires when the execution result arrives. |

### 15. AggregateCommitVotes

| Field | Value |
|-------|-------|
| **Spec action** | `AggregateCommitVotes` |
| **Code location** | `buffer_item.rs:237-255` (advance to Aggregated from Signed) |
| **Trigger point** | After buffer item transitions from Signed to Aggregated |
| **Trace event name** | `"AggregateCommitVotes"` |
| **Fields** | State snapshot + `round` |
| **Notes** | Family 3: This means 2f+1 commit votes collected. |

### 16. PersistBlock

| Field | Value |
|-------|-------|
| **Spec action** | `PersistBlock` |
| **Code location** | `buffer_manager.rs` persisting_phase |
| **Trigger point** | After the persisting phase completes and the block is committed to storage |
| **Trace event name** | `"PersistBlock"` |
| **Fields** | State snapshot + `round` + `committedRound` |
| **Notes** | Family 3: This is the final commit. After this, the block is durable. |

### 17. ResetPipeline

| Field | Value |
|-------|-------|
| **Spec action** | `ResetPipeline` |
| **Code location** | `buffer_manager.rs:546-570` (`reset`) |
| **Trigger point** | After reset completes (all items drained) |
| **Trace event name** | `"ResetPipeline"` |
| **Fields** | State snapshot |
| **Notes** | Family 3: Pipeline reset clears all in-flight items. Triggered by sync or epoch change. |

### 18. EpochChange

| Field | Value |
|-------|-------|
| **Spec action** | `EpochChange` |
| **Code location** | `safety_rules.rs:265-344` (`guarded_initialize`) + `epoch_manager.rs` |
| **Trigger point** | After `persistent_storage.set_safety_data()` with new epoch (line 296-303) |
| **Trace event name** | `"EpochChange"` |
| **Fields** | Full state snapshot (all safety data reset to 0) + new epoch number |
| **Notes** | Family 5: Safety data is reset. All round-tracking variables go to 0. |

## Section 3: Special Considerations

### 3.1 Safety Data Access

Safety data is stored in `PersistentSafetyStorage` (safety_rules.rs:42). For tracing:
- In `local` mode (same process): access via `SafetyRules::consensus_state()` after each action
- In `remote` mode (separate process): must instrument the `TSafetyRules` trait implementation to capture post-state

The `ConsensusState` struct provides a snapshot: epoch, last_voted_round, preferred_round, and whether the signer is available.

### 3.2 Pipeline Events in BufferManager

Pipeline events (ExecuteBlock, SignCommitVote, AggregateCommitVotes, PersistBlock) occur in `BufferManager`, which runs as a separate task from `RoundManager`. Events from these two components will interleave in the trace.

The trace spec handles this via separate action wrappers that don't require round synchronization between the pipeline and round manager.

### 3.3 Two Timeout Code Paths

`process_local_timeout` has two distinct code paths controlled by `enable_round_timeout_msg`:
- **Path A** (line 1021-1059): Creates `RoundTimeout`, broadcasts via `broadcast_round_timeout`
- **Path B** (line 1061-1105): Creates timeout vote (may include NIL block vote), broadcasts via `broadcast_timeout_vote`

Both paths call `sign_timeout_with_qc`. The trace event `"SignTimeout"` should be emitted from BOTH paths with the same field schema.

### 3.4 Self-Votes

After `CastVote`, the vote is also delivered locally (self-vote). The `ReceiveVote` trace event for a self-vote (source == nid) is handled as a no-op in the trace spec. Similarly for `CastOrderVote` → `ReceiveOrderVote` and `SignTimeout` → `ReceiveTimeout`.

Recommendation: either (a) do not emit `ReceiveVote` for self-votes, or (b) emit them and let the trace spec skip them.

### 3.5 Epoch Check in Release Builds

`timeout_2chain.rs:248-257` uses `debug_assert_eq` for epoch/round checks in TC aggregation. These are compiled out in release builds. The instrumentation should capture the epoch field on all timeout messages to detect cross-epoch TC formation (Family 5, MC-3).

### 3.6 Order Vote 100-Round Window

`process_order_vote_msg` (round_manager.rs:1592-1593) uses a 100-round window instead of `ensure_round_and_sync_up`. This means order votes from far-future rounds are silently dropped. The trace should capture the `highestOrderedRound` to verify the window check.

### 3.7 Crash Events

Crash and recovery events (Family 4) are not directly instrumentable in normal execution. For crash testing:
- Use `fail_point!` macros (already present in the code, e.g., line 1569)
- Or use an external test harness that kills/restarts processes
- The trace spec's `Crash`/`Recover` actions can be matched to process restart events
