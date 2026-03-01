# Bug Report: Missing Ack/NewLeaderAck ordering barrier at recovery boundary

## Summary
The implementation has no barrier ensuring:

> if a replica sends `Ack` at ballot `b` and `NewLeaderAck` at ballot `b' > b`, it sends `Ack` before `NewLeaderAck`.

At recovery start, `NewLeaderAckN` is sent immediately, while old `Ack` traffic can still be emitted asynchronously from `batcher`.

## Invariant potentially violated
- `invariants/invariants.png`:
  - "If a replica sends an Ack message at ballot `b` and a NewLeaderAck(`b'`, ...) message with `b' > b` then it sends Ack before sending NewLeaderAck."

## Repro (code-path)
1. Before recovery, replica enqueues an old-ballot Ack into `batcher`:
   - `handlePropose` -> `r.batcher.SendFastAck(...)` at `artifact/swiftpaxos/swift/swift.go:424`
   - or `fastAckFromLeader` -> `r.batcher.SendLightSlowAck(...)` at `artifact/swiftpaxos/swift/swift.go:506`
2. Replica receives `NewLeader(b')` and enters recovery:
   - `handleNewLeader` at `artifact/swiftpaxos/swift/recovery.go:15`
   - immediately sends `NewLeaderAckN` at `artifact/swiftpaxos/swift/recovery.go:41`
3. `batcher` is not stopped/drained by recovery and continues running:
   - goroutine loop at `artifact/swiftpaxos/swift/batcher.go:23`
   - second branch at `artifact/swiftpaxos/swift/batcher.go:144`
4. `batcher` can still emit old-ballot `Ack` (`MAcks` / `MOptAcks`) after step 2.
5. Both `NewLeaderAckN` and `Ack` go through the shared async sender channel:
   - sender queue: `artifact/swiftpaxos/replica/sender.go:33`
   - sender loop: `artifact/swiftpaxos/replica/sender.go:35`

Because producer goroutines (`run` vs `batcher`) race to enqueue into sender, there is no guarantee old `Ack` is enqueued before `NewLeaderAckN`.

## Root cause
- Recovery stops `repchan` and descriptor handlers (`recovery.go:30`, `recovery.go:31`) but does not stop or flush `batcher`.
- No explicit "drain all pending Ack sends before sending NewLeaderAckN" logic exists.
- No TODO in code marks this ordering invariant as intentionally unimplemented.

## Suggested fix direction
- Add an ordering barrier in recovery:
  - quiesce/flush `batcher` pending old-ballot acks before `SendTo(...NewLeaderAckN...)`, or
  - gate `batcher` sends by current recovery state/ballot so stale-ballot acks are dropped once recovering.
