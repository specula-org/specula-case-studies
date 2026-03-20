# Instrumentation Spec: Tarantool Raft

Maps TLA+ spec actions to source code locations for trace harness generation.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node": <server_id>,
  "state": "<follower|candidate|leader>",
  "volatileTerm": <int>,
  "volatileVote": <int|0>,
  "persistedTerm": <int>,
  "persistedVote": <int|0>,
  "leader": <int|0>,
  "isWriteInProgress": <bool>,
  "leaderWitnessMap": [<int>, ...],
  ...event-specific fields...
}
```

### State Fields (captured at every event)

| Implementation field | TLA+ variable | Getter |
|---|---|---|
| `raft->state` | `state` | `raft_state_str(raft->state)` |
| `raft->volatile_term` | `volatileTerm` | direct field |
| `raft->volatile_vote` | `volatileVote` | direct field (0 = Nil) |
| `raft->term` | `persistedTerm` | direct field |
| `raft->vote` | `persistedVote` | direct field (0 = Nil) |
| `raft->leader` | `leader` | direct field (0 = Nil) |
| `raft->is_write_in_progress` | `isWriteInProgress` | direct field |
| `raft->leader_witness_map` | `leaderWitnessMap` | bitmap → array of set bits |

### Message Fields (for message events)

| Implementation field | TLA+ field | Notes |
|---|---|---|
| `req->term` | `term` | |
| `req->vote` | `vote` | 0 = Nil |
| `req->leader_id` | `leaderId` | 0 = Nil |
| `req->state` | `state` | |
| `req->is_leader_seen` | `isLeaderSeen` | |
| `req->vclock` | `vclock` | Array, NULL → empty |

## Section 2: Action-to-Code Mapping

### 1. ElectionTimeout

- **Spec action**: `ElectionTimeout(s)`
- **Code location**: `raft.c:966-983` (`raft_sm_election_update_cb`)
- **Trigger point**: After `raft_ev_timer_stop` (line 977), before `raft_sm_election_update` (line 982)
- **Trace event**: `election_timeout`
- **Fields**: state snapshot + `leaderWitnessMap` (after self bit clear)
- **Notes**: Timer callback. The self bit is already cleared at line 978 when we capture state. Capture AFTER `bit_clear` but BEFORE `raft_sm_election_update` to see intermediate state. Alternatively, capture AFTER `raft_sm_election_update` to see final state (new term if election started).

### 2. ReceiveMessage

- **Spec action**: `ReceiveMessage(s, m)`
- **Code location**: `raft.c:503-654` (`raft_process_msg`)
- **Trigger point**: After all processing (before `return 0` at lines 627, 631, 641, 653)
- **Trace event**: `receive_message`
- **Fields**: state snapshot + `from` (source), `to` (self), message fields
- **Notes**: Multiple return paths. Instrument at each return point, or instrument once at function exit. The `source` parameter gives `from`. Capture state AFTER processing for post-state validation.

### 3. ReceiveHeartbeat

- **Spec action**: `ReceiveHeartbeat(s, m)`
- **Code location**: `raft.c:656-696` (`raft_process_heartbeat`)
- **Trigger point**: After `raft_sm_wait_leader_dead` (line 695) or after early return (line 680)
- **Trace event**: `receive_heartbeat`
- **Fields**: state snapshot + `from` (source), `to` (self)
- **Notes**: During WAL write (line 679-680), heartbeat is effectively a no-op. Still emit trace event to validate the no-op path.

### 4. WalWriteTermOnly

- **Spec action**: `WalWriteTermOnly(s)`
- **Code location**: `raft.c:759-760` (`raft_worker_handle_io`, `goto do_dump` path)
- **Trigger point**: After `raft_write` (line 783), before next `raft_is_fully_on_disk` check
- **Trace event**: `wal_write_term_only`
- **Fields**: state snapshot (shows term advanced, vote still Nil in persisted)
- **Notes**: This is the first pass of multi-pass WAL write. Term is persisted (line 787), vote stays 0 (line 788 with req.vote=0).

### 5. WalWriteTermAndVote

- **Spec action**: `WalWriteTermAndVote(s)`
- **Code location**: `raft.c:769-784` (`raft_worker_handle_io`, `do_dump_with_vote` path)
- **Trigger point**: After `raft_write` (line 783)
- **Trace event**: `wal_write_term_and_vote`
- **Fields**: state snapshot (shows both term and vote persisted)
- **Notes**: Either self-vote (line 749-750) or foreign vote after vclock recheck passes (line 761).

### 6. WalWriteRevokeVote

- **Spec action**: `WalWriteRevokeVote(s)`
- **Code location**: `raft.c:761-768` (`raft_worker_handle_io`, vclock recheck fails)
- **Trigger point**: After `raft_revoke_vote` (line 765)
- **Trace event**: `wal_write_revoke_vote`
- **Fields**: state snapshot (volatileVote reset to 0)
- **Notes**: The log message at line 762-763 ("vote request for %u is canceled") is a natural instrumentation point.

### 7. WalWriteTermOnlyNonVote

- **Spec action**: `WalWriteTermOnlyNonVote(s)`
- **Code location**: `raft.c:740-741` + `raft.c:771-784` (volatileVote==0 → `goto do_dump`)
- **Trigger point**: After `raft_write` (line 783)
- **Trace event**: `wal_write_term_no_vote`
- **Fields**: state snapshot
- **Notes**: Path where only term changed, no vote. `volatile_vote == 0` at line 740 → jumps to `do_dump`.

### 8. CompleteWalWrite

- **Spec action**: `CompleteWalWrite(s)`
- **Code location**: `raft.c:707-736` (`raft_worker_handle_io`, `end_dump` label)
- **Trigger point**: After `raft->is_write_in_progress = false` (line 709), after state transition
- **Trace event**: `complete_wal_write`
- **Fields**: state snapshot (isWriteInProgress=false, final state after transition)
- **Notes**: Capture AFTER the post-write state transitions (become_leader/become_candidate/wait_*). Multiple exit paths at lines 717, 722, 724, 730, 733.

### 9. BroadcastRaftState

- **Spec action**: `BroadcastRaftState(s)`
- **Code location**: `raft.c:799-807` (`raft_worker_handle_broadcast`)
- **Trigger point**: After `raft_broadcast` (line 805)
- **Trace event**: `broadcast_state`
- **Fields**: state snapshot + broadcast message fields (term, vote, state, leader_id, is_leader_seen, vclock)
- **Notes**: Uses persisted state for broadcast content (raft_checkpoint_remote).

### 10. LeaderSendHeartbeat

- **Spec action**: `LeaderSendHeartbeat(s)`
- **Code location**: `box/raft.c` heartbeat path (applier/relay heartbeat emission)
- **Trigger point**: When heartbeat is sent
- **Trace event**: `send_heartbeat`
- **Fields**: `node` (sender)
- **Notes**: Heartbeats originate from the relay subsystem, not the core raft.c. Instrument at the point where heartbeat is dispatched.

### 11. Crash

- **Spec action**: `Crash(s)`
- **Code location**: Test harness — not a code location, triggered externally
- **Trigger point**: Before node restart in test scenario
- **Trace event**: `crash`
- **Fields**: `node` (crashing server)
- **Notes**: Crash is a test-controlled event. Emit before calling raft_create + raft_process_recovery.

### 12. Promote

- **Spec action**: `Promote(s)`
- **Code location**: `raft.c:1212-1220` (`raft_promote`)
- **Trigger point**: After `raft_sm_schedule_new_vote` (line 1219)
- **Trace event**: `promote`
- **Fields**: state snapshot
- **Notes**: Capture AFTER all promote actions complete to see final volatile state.

### 13. LeaderResign

- **Spec action**: `LeaderResign(s)`
- **Code location**: `raft.c:1223-1228` (`raft_resign`) → `raft_stop_candidate`
- **Trigger point**: After `raft_stop_candidate` (line 1227)
- **Trace event**: `leader_resign`
- **Fields**: state snapshot
- **Notes**: State transitions to Follower, leader cleared.

### 14. NotifyLeaderSeen

- **Spec action**: `NotifyLeaderSeen(s, source, isSeen)`
- **Code location**: `raft.c:455-468` (`raft_notify_is_leader_seen`)
- **Trigger point**: After bit set/clear (lines 465-467)
- **Trace event**: `notify_leader_seen`
- **Fields**: state snapshot + `source`, `isLeaderSeen`
- **Notes**: Called from raft_process_msg (line 531). If instrumenting separately, beware of double-counting with ReceiveMessage.

### 15. AdvanceVclock

- **Spec action**: `AdvanceVclock(s)`
- **Code location**: WAL write completion / transaction commit in box subsystem
- **Trigger point**: After vclock component increment
- **Trace event**: `advance_vclock`
- **Fields**: `node`, `vclock` (full vclock array)
- **Notes**: Vclock advances happen outside raft.c when transactions commit. Instrument at WAL write completion (`wal_write_to_disk` or equivalent). Only needed for traces testing vclock-related vote revocation (Family 3).

## Section 3: Special Considerations

### Dual State Access
The raft struct exposes both volatile (`volatile_term`, `volatile_vote`) and persisted (`term`, `vote`) fields directly. Both must be captured at each event for post-state validation.

### Leader Witness Map Serialization
`leader_witness_map` is a `vclock_map_t` (bitmap). Serialize as JSON array of set bit positions:
```c
// Example: leader_witness_map = 0b1010 → [1, 3]
```

### WAL Write Multi-Pass
The `raft_worker_handle_io` function contains a loop with `goto` labels (`do_dump`, `do_dump_with_vote`, `end_dump`). Each pass through `raft_write` should emit a separate trace event. The function may call `raft_write` twice in a single invocation (term-only, then term+vote after recheck).

### Single-Threaded Model
Tarantool Raft runs in a single cooperative fiber. No concurrent access to raft state within a single node. Events within one node are strictly ordered.

### Heartbeat Origin
Heartbeats are NOT sent from `raft.c` directly. They come from the relay subsystem. For trace validation, instrument at `raft_process_heartbeat` entry (the receiver side) rather than trying to trace heartbeat sending.

### Recovery
`raft_process_recovery` (raft.c:422-453) applies WAL entries during restart. For crash+recovery traces, emit a `crash` event followed by recovery state. The recovery function is called multiple times (once per WAL entry), but the spec models crash as atomic reset to persisted state.

### NotifyLeaderSeen vs ReceiveMessage
`raft_notify_is_leader_seen` is called from within `raft_process_msg` (line 531). When instrumenting, decide whether to:
1. Emit as part of `receive_message` event (include `isLeaderSeen` field) — simpler
2. Emit as separate `notify_leader_seen` event — more granular

Option 1 is recommended for initial instrumentation. The Trace spec's `ReceiveMessage` wrapper handles the witness map update internally.

### Vclock Representation
Vclocks in the implementation use a fixed-size array indexed by instance ID. In JSON traces, represent as an object mapping server ID to counter: `{"1": 5, "2": 3, "3": 7}`. The TLA+ spec uses `[Server -> Nat]`.
