# Bug Report: Commands in `START` can appear in newly computed dependencies

## Summary
SwiftPaxos can assign a dependency on a command that is still in local `START` phase, violating the invariant:

> At a replica, whenever a command is in `START`, it does not belong to the dependencies of any command.

This appears to be an implementation ordering/design issue in dependency indexing and propose handling.

## Reproduction

### Code-path repro (no instrumentation required)
The following interleaving is sufficient:

1. Replica receives proposal for command `c1` on key `k` in `run()`:
   - `swift.go:278` enters `ProposeChan` case.
   - `swift.go:282` calls `getDepAndHashes(c1)`.
   - Inside `getDepAndHashes`, replica updates key index immediately via `info.add(c1)` at `swift.go:833`.
2. `c1` descriptor is still at `START` (`swift.go:698`) until `handlePropose` runs and sets `PRE_ACCEPT` at `swift.go:380`.
   - On non-sequential path, message processing is asynchronous (`swift.go:667`, `swift.go:668`), so this transition can lag.
3. Before `c1` reaches `PRE_ACCEPT`, replica receives proposal for conflicting command `c2` on same key:
   - `swift.go:282` calls `getDepAndHashes(c2)` again.
   - Conflict lookup (`swift.go:827`) uses `keyInfo.getConflictCmds`, which is phase-agnostic (`key.go:93`, `key.go:131`).
4. Therefore `c1` is returned as a dependency of `c2` even though `c1` is still in local `START`.

This reproduces the bug by construction from current control flow and data structure semantics.

## Root Cause

1. Dependencies are computed from per-key conflict indexes at submit time:
   - `artifact/swiftpaxos/swift/swift.go:282`
   - `artifact/swiftpaxos/swift/swift.go:827`
2. The new command is inserted into those indexes immediately in the same function:
   - `artifact/swiftpaxos/swift/swift.go:833`
3. Conflict indexes are phase-agnostic (only track last conflicting command ids):
   - `artifact/swiftpaxos/swift/key.go:93`
   - `artifact/swiftpaxos/swift/key.go:131`
4. Command descriptors start at `START` and may remain there while propose handling is queued/asynchronous:
   - `artifact/swiftpaxos/swift/swift.go:698`
   - `artifact/swiftpaxos/swift/swift.go:667`
   - `artifact/swiftpaxos/swift/swift.go:668`
   - phase change to `PRE_ACCEPT` happens later in `handlePropose`: `artifact/swiftpaxos/swift/swift.go:380`

Net effect: dependency lookup can pick commands that are known but still in `START`.

## Impact
- Violates protocol invariant expectations used for formal modeling and validation.
- Can create transient dependency graphs that include non-propagated commands, complicating safety reasoning and recovery behavior.

## Suggested Fix Directions
- Make dependency computation phase-aware (exclude candidates still in `START`).
- Or delay conflict-index insertion until command reaches `PRE_ACCEPT` (or stronger phase).
- Re-check behavior under pipelining/out-of-order arrivals (there are existing ordering caveats in `swift.go` comments near propose/fast-ack handling).

---

## Proposed concrete code changes (not applied)

1. Phase-aware filtering in `getDepAndHashes` (smallest change)
- In `artifact/swiftpaxos/swift/swift.go` inside `getDepAndHashes`:
  - after `cdep := info.getConflictCmds(cmd)` (`swift.go:827`), filter out command ids whose local phase is `START`.
  - keep only deps with local phase `>= PRE_ACCEPT` (or `>= ACCEPT` if you want stricter behavior).
- Add helper in `swift.go`, e.g. `isDepEligible(cmdId CommandId) bool`, checking phase in `cmdDescs`.

2. Delay conflict-index insertion until phase transition
- Refactor `getDepAndHashes` (`swift.go:819`) so dep computation and index insertion are separate steps.
- Move `info.add(cmd, cmdId)` (currently `swift.go:833`) to happen when command reaches `PRE_ACCEPT` in `handlePropose` (`swift.go:380` path), not at initial submit.

3. Add dep sanitization before fast-ack emit
- In `handlePropose` before creating/sending `MFastAck` (`swift.go:397+`):
  - deduplicate deps,
  - remove any ineligible (`START`) dep ids,
  - optionally recompute or force slow path if sanitization changes dep.

4. Add instrumentation/assertions for regression detection
- Log/assert when a dep candidate is dropped for being in `START`.
- Add a test where two conflicting proposals arrive quickly on the same replica; assert the second does not include the first while first remains `START`.
