# Bug Report: Recovery merge can nondeterministically overwrite conflicting command state

## Summary
During recovery, the leader merges `NewLeaderAckN` payloads by plain map assignment.  
If two acks at selected `Cballot` disagree on `(cmdId -> phase/cmd/dep)`, one silently overwrites the other based on map iteration order.

## Invariants potentially violated
- `invariants/invariants.md`:  
  - "Any two replicas commit a command with the same set of dependencies."
- `invariants/invariants.png` (Ack/Sync/NewLeaderAck section):  
  - Leader/ballot consistency expectations for `Ack`, `Sync`, and recovered `dep`.
- `invariants/invariants.md`:  
  - "The committed part of the dependency graph at each replica is acyclic." (can be affected by inconsistent dep choice)

## Repro (code-path)
Construct recovery with two `MNewLeaderAckN` messages in the selected set `U` (same max `Cballot`) that both include the same `cmdId` but different `dep` (or `phase`/`cmd`).

In `handleNewLeaderAckNs`:
- selected set built at `artifact/swiftpaxos/swift/recovery.go:82`
- merged with overwrite semantics at:
  - `artifact/swiftpaxos/swift/recovery.go:102`
  - `artifact/swiftpaxos/swift/recovery.go:106`
  - `artifact/swiftpaxos/swift/recovery.go:107`
  - `artifact/swiftpaxos/swift/recovery.go:108`

No equality/conflict check exists before overwrite.

Why nondeterministic:
- `MsgSet` materializes `msgs` by iterating a Go map: `artifact/swiftpaxos/replica/mset.go:79`
- recovery iterates map `U`: `artifact/swiftpaxos/swift/recovery.go:102`

Both iteration orders are unspecified, so chosen value for same `cmdId` is unstable.

## Root cause
Recovery merge assumes equal-`Cballot` snapshots are mutually consistent, but does not verify that assumption.  
Also, `cballot` is not maintained in normal operation (mostly init/recovery only), weakening the selection criterion:
- init: `artifact/swiftpaxos/swift/swift.go:173`
- sent: `artifact/swiftpaxos/swift/recovery.go:36`
- reset on sync install: `artifact/swiftpaxos/swift/recovery.go:210`

## Suggested fix direction
- Add explicit conflict detection while merging equal-`Cballot` acks; reject or deterministically resolve conflicts.
- Strengthen freshness metadata (per-command ballot/version) instead of global `Cballot` only.
