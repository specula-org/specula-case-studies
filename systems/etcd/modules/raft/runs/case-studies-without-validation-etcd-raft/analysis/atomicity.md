# Atomicity Boundaries: etcd-raft

## Single-Threaded Core

The raft state machine is single-threaded. All mutations happen within a single `Step()` call on the `raft` struct. There are no goroutines inside the raft library — concurrency is managed by the caller via `node.go` or `rawnode.go`.

**Key implication for modeling**: Each `Step()` call is atomic. Between Step calls, no state changes. This simplifies TLA+ modeling significantly.

## Atomic Actions (within a single Step call)

1. **Receiving a message and updating state**: A single `Step(m)` call can:
   - Update term, become follower (raft.go:1092-1123)
   - Process the message type (vote, append, heartbeat, etc.)
   - Generate response messages
   - All of this is atomic

2. **Leader appending entries**: `appendEntry()` (raft.go:815-847)
   - Appends to unstable log
   - Sends self-ack MsgAppResp (to msgsAfterAppend)
   - Broadcasts MsgApp to followers
   - All atomic

3. **Config change application**: `applyConfChange()` (raft.go:1947-1967) + `switchToConfig()` (raft.go:1975-2031)
   - Changes config atomically
   - May trigger leader step-down
   - May advance commit index
   - Atomic

## Non-Atomic Sequences (between Step calls)

1. **Persistence and message delivery**: Between `Step()` and the caller persisting to disk:
   - Entries in `msgs` can be sent before persistence
   - Entries in `msgsAfterAppend` must wait for persistence
   - A crash between Step and persistence loses the mutations

2. **Config change proposal vs application**:
   - Proposal happens in one Step (appends to log)
   - Application happens much later (after commit, after Ready delivery)
   - Multiple Steps can occur between proposal and application

3. **Election timeout**: Each `tickElection()` call is separate from message processing

## Modeling Implications

For TLA+:
- Model each action as atomic (one server acts per step)
- Model message delivery as separate action
- Model config change application as separate action from proposal
- Model crashes as losing all volatile state (but keeping HardState)
- Message channels: unreliable, unordered (can lose, duplicate, reorder)
