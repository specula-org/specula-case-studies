# arc-swap_2 — Spec Validation Changelog

## Round 1 - Trace Validation
- Both traces (basic_read_write, concurrent_readers_writer) pass on first run.

## Round 1 - Model Checking
- [fix-spec] ReaderFallbackControlSwap (Case B): on generation wrap, spec
  incremented activeWriters[t] but never decremented it, causing TLC deadlock —
  CheckCooldown is gated by activeWriters=0 and cooldown could never be released.
  In list.rs:115-120, `start_cooldown` does `let _reservation = self.reserve_writer();`
  whose `NodeReservation` Drop (list.rs:54-58) decrements active_writers at end
  of scope. Net change is zero. Changed spec to UNCHANGED activeWriters in the
  wrapped branch.
- [fix-inv] CooldownReleaseObservesZero (Case A): state invariant
  `nodeState[n]=UNUSED => activeWriters[n]=0` is too strong. After CheckCooldown
  releases a node COOLDOWN→UNUSED, a writer holding a stale wToVisit snapshot
  can immediately reserve the now-UNUSED node — `Node::get`'s CAS UNUSED→USED
  does not consult active_writers. The actual safety property (the
  COOLDOWN→UNUSED transition observes activeWriters=0) is already enforced by
  CheckCooldown's action guard. Disabled the state invariant in MC.cfg and
  Trace.cfg.
- [fix-spec] WriterTraverseLoad (Case B): livenodes was incorrectly filtered to
  `{n : nodeState[n] # NODE_UNUSED}`, but `Node::traverse` (debt/list.rs:93-112)
  walks the WHOLE linked list regardless of node in_use state — nodes are never
  freed (list.rs:6-9). When a node became UNUSED mid-pay_all (via cooldown wrap
  by a third thread), the spec's writer skipped it, leaving a still-held debt
  unpaid — eventually triggering DeadRefCountZero violation when the guard's
  later GuardIntoInner re-incremented refCount on a freshly-zero address.
  Changed livenodes to `Thread` (every node is in the list always).

## Round 2 - Trace Validation
- Both traces pass (no regressions from the Phase 2 spec changes).

## Round 2 - Model Checking
- MC.cfg completed cleanly: 9,220,915 states / 2,017,751 distinct, depth 78, no
  invariant violations. Spec converged.

## Result
Converged in 2 rounds. Proceeding to bug hunting.

## Round 3 - Bug Hunting Adjustments
- BFS results before invariant tightening:
  - Family A: violation MCPayAllCompleteness at depth 14 (33,127 states), trigger
    `PickRelaxSite("ListHeadLoad")` — historical-class bug (Case C).
  - Family B: NoUseAfterFree fired at depth 18 — but the violating state had
    only a transient stale slot value with all guards still NULL → Case A
    indication that the slot-level clause was too strict.
  - Family C: deadlock at depth 1 — `MCDropArcSwap` legitimately quiesces the
    system (no bug).  Re-running with `-deadlock` (TLC's flag *disables*
    deadlock checking) avoids the false alarm.
  - Family D: same NoUseAfterFree pattern as Family B (transient slot only).
  - Family E: same trigger as Family A (PayAllCompleteness with relaxed
    ListHeadLoad).

- [fix-inv] NoUseAfterFree (Case A): the slot-level clause
  `SlotValue(t,s) # NullPtr => addrAlive[SlotValue(t,s)]` was too strong and
  fired on a transient state in Family B's BFS run: writer's pay_all completed
  before reader acquired its slot, then reader did `SlotAcquire` writing the
  now-freed wOldAddr into its fastSlot. In the implementation, the reader's
  next SC confirm-load observes the new storage and the Resolve CAS clears the
  slot — no dereference occurs. Slots are CAS targets, not live refs.
  Modeling-brief.md §5 only specifies "No Guard's underlying Arc has refcount 0".
  Reduced NoUseAfterFree to `NoStaleGuard` alone. PayAllCompleteness still
  covers the slot-level "writer returned with unpaid debts" case.

## Round 4 - Re-converge after invariant fix
- MC.cfg passes again: 9,220,915 states / 2,017,751 distinct, depth 78,
  duration 36s. No errors.

## Round 5 - Bug-Hunt Re-runs
- Family A BFS:    PayAllCompleteness violated at depth 14 (Case C, historical).
- Family A `-C`:   23,942 NoUseAfterFree + 8,521 PayAllCompleteness violations
  across all 9 named SC sites (Case C, historical-class).
- Family B BFS:    no errors (depth 248, 7,553,928 distinct states).
- Family C BFS:    aborted at depth 39 (TLC offheap state-pool disk quota);
  no violation in 48,431,117 distinct states.
- Family C sim:    depth-100 simulation, 30-min timeout, 535,691,601 states /
  2,248,527 traces, no violations.
- Family D BFS:    no errors (depth 248, 7,553,928 distinct states).
- Family E BFS:    PayAllCompleteness violated at depth 14 (same scenario as
  Family A).

## Result
Converged in 2 rounds.  Bug hunting:
- 2 families (A, E) reproduce historical bug classes by relaxing SC labels;
- 2 families (B, D) explored exhaustively at depth 248 with no violations;
- 1 family (C) explored to BFS depth 39 / 48M distinct states + 535M simulation
  states with no violations.
No previously-unknown bugs were found in the current implementation.
