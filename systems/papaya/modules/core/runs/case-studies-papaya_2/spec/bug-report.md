# Bug Report — papaya (Lock-Free Concurrent HashMap)

## Summary

- Bug families tested: 6 (parker_deadlock, meta_overwrite, iter_double_yield, iter_weak_snapshot, resize_race, reclamation)
- Bugs found: **3** confirmed real bugs (matching modeling-brief expected findings MC-1, MC-2, plus a new iter-yield finding)
- Spec issues found and fixed during hunting: 1 (Case B — CopyInsertToNext one-shot guard)
- Configs run: MC_hunt_parker_deadlock, MC_hunt_meta_overwrite, MC_hunt_iter_double_yield, MC_hunt_iter_weak_snapshot, MC_hunt_resize_race, MC_hunt_reclamation

---

## Bug 1: Wrong-Parker Routing on Blocking Resize Abort

- **Bug Family**: 3 — Parker / Unpark Routing (D2-1)
- **Severity**: **High** — confirmed liveness bug, in-tree reproducer (`tests/repro_parker_deadlock.rs`), still unfixed on upstream master `b510b15`
- **Invariant violated**: `NoParkedOnAborted` (no thread is ever parked on a table whose status is ABORTED)
- **Config**: `MC_hunt_parker_deadlock.cfg`
- **Counterexample**: 5 states, depth 7, found in 5 s; output `spec/output/MC_hunt_parker_deadlock_bfs.out`

### Trace Summary

| State | Action | Effect |
|-------|--------|--------|
| 1 | initial | rootTable=NULL |
| 2 | `MCInitTable(t1)` | rootTable=1, status[1]=PROMOTED |
| 3 | `MCAllocNextTable(t1, 1)` | nextTable[1]=2, status[2]=PENDING |
| 4 | `MCParkThread(t1, 1)` | t1 parks on `(parker=2, key=2)` — keyed on next.state().status (mod.rs:2400-2402) |
| 5 | `MCAbortResize(t1, src=1, abortedT=2)` | status[2] := ABORTED. The buggy unpark targets `(parker=1, key=1)` — the SOURCE table — but t1 is parked on the destination's `(parker=2, key=2)`. t1 stays parked. |

After State 5: `parked[t1] = [parker |-> 2, key |-> 2]` while `resizeStatus[2] = ABORTED`. The thread will sleep forever.

### Root Cause

`raw/mod.rs:2336-2337` (the abort branch of `help_copy_blocking`):

```rust
let state = table.state();         // SOURCE table's state
state.parker.unpark(&state.status); // unparks (source.parker, &source.status)
```

But threads parked at `raw/mod.rs:2400-2406`:

```rust
state /* = next.state() */
    .parker
    .park(&state.status, |status| status == State::PENDING);
```

are parked under `(next.parker, &next.status)`. Two different parker objects, two different keys. The `unpark` call wakes nobody.

### Affected Code

- `artifact/papaya/src/raw/mod.rs:2336-2337` — buggy unpark target
- `artifact/papaya/src/raw/mod.rs:2400-2406` — park target (correctly uses `next` table)
- `artifact/papaya/src/raw/utils/parker.rs` — Parker::unpark removes by (parker, key) tuple

### Recommendation

Replace `state.parker.unpark(&state.status)` at mod.rs:2337 with `next.state().parker.unpark(&next.state().status)`. This is the fix proposed in the (specula-org-fork) PR #92 that was never merged into upstream. Land it on `ibraheemdev/papaya` master.

---

## Bug 2: META Overwrite — Phase-2 Store Clobbers TOMBSTONE

- **Bug Family**: 7 — Slot Recycling / META Overwrite (D2-4)
- **Severity**: **Medium** — slot-leak / probe-chain bloat, not memory-unsafe; in-tree reproducer (`tests/repro_bug1_meta_overwrite.rs`); `META_OVERWRITE_BUG_COUNT` static at `lib.rs:250` confirms reproducibility
- **Invariant violated**: `NoStaleMetaOnEmptySlot` (a slot whose entry is NULL must not have meta `\notin {EMPTY, TOMBSTONE}`)
- **Config**: `MC_hunt_meta_overwrite.cfg`
- **Counterexample**: 5 states, depth 11, found in 16 s; output `spec/output/MC_hunt_meta_overwrite_bfs.out`

### Trace Summary

| State | Action | Effect |
|-------|--------|--------|
| 1 | initial | empty |
| 2 | `MCInitTable(t1)` | rootTable=1 |
| 3 | `MCInsertCASEntry(t1, k1, v1, 1, 0)` | tableEntry[1][0] := [k1, v1, {}]; insertWindow[1][0] := t1; metaWritten[1][0]=FALSE |
| 4 | `MCRemove(t1, k1, 1, 0)` | tableEntry[1][0] := NULL; tableMeta[1][0] := TOMBSTONE; metaWritten[1][0] := TRUE. **insertWindow[1][0] is deliberately not cleared** — winner's Phase-2 store is still pending. |
| 5 | `MCInsertStoreMeta(t1, 1, 0)` | The winner's UNCONDITIONAL Release-store at mod.rs:1051 fires. Even though `tableEntry=NULL` and `tableMeta=TOMBSTONE`, the spec branches to "tableEntry=NULL ∧ tableMeta=TOMBSTONE" and writes `tableMeta := h2(k1) = "k1"`. **Now: tableEntry=NULL, metaWritten=TRUE, tableMeta="k1"** — the stale-meta-on-empty-slot state. |

### Root Cause

The two-phase insert at `raw/mod.rs:1014-1111` writes the entry pointer (Phase 1, CAS at line 1028) and then writes the meta byte (Phase 2, store at line 1051) as separate atomic operations. The yield-loop at line 1047 widens the window. If a concurrent `Remove` lands during the yield, it:

1. CAS-tombstones the entry pointer (mod.rs:769, `update_at` → TOMBSTONE_PTR).
2. Stores `meta::TOMBSTONE` at mod.rs:782-786.

Then the original winner's Phase 2 fires unconditionally, overwriting `meta::TOMBSTONE` with `h2(k)`.

The slot is no longer recyclable (`mod.rs:1336, 3070` only treat `meta ∈ {EMPTY, TOMBSTONE}` as reusable). Subsequent inserts probe past it, and only a full-table copy resets it.

### Affected Code

- `artifact/papaya/src/raw/mod.rs:1051` — winner's unconditional `meta_entry.store(meta, Release)` (Phase 2)
- `artifact/papaya/src/raw/mod.rs:1336, 3070` — slot reusability check requiring `meta ∈ {EMPTY, TOMBSTONE}`
- `artifact/papaya/src/raw/mod.rs:1106-1108` — loser fixup; correctly conditional on `meta == EMPTY`
- `artifact/papaya/tests/repro_bug1_meta_overwrite.rs` — existing reproducer

### Recommendation

Make the Phase-2 store conditional analogous to the loser fixup: re-load the entry pointer (or check meta is still EMPTY) immediately before the Release store, and skip the store if the slot has been tombstoned. Equivalent to making the winner CAS its meta byte rather than blind-store. Performance impact is minor since the contended-slot path is uncommon.

---

## Bug 3: Iterator Double-Yield Across Insert/Remove/Reinsert

- **Bug Family**: 6 — Adversarial Caller, Iter+Modify+Resize (extension of MC-4)
- **Severity**: **Medium** — semantic surprise (caller sees same key twice from a single iteration); not memory-unsafe; depends on whether `HashMap::iter` API contract intends to forbid this
- **Invariant violated**: `IterNoDoubleYield` (`∀tid : seenKeys[tid] has no duplicate`)
- **Config**: `MC_hunt_iter_double_yield.cfg`
- **Counterexample**: 10 states, depth 11, found in 7 s; output `spec/output/MC_hunt_iter_double_yield_bfs.out`

### Trace Summary

| State | Action | Effect |
|-------|--------|--------|
| 1 | initial | empty |
| 2 | `MCInitTable(t1)` | rootTable=1 |
| 3 | `MCInsertCASEntry(t1, k1, v1, 1, 0)` | k1 in slot 0 |
| 4 | `MCIterBegin(t1)` | iterTable[t1]=1, iterIdx=0, seenKeys=⟨⟩ |
| 5 | `MCInsertStoreMeta(t1, 1, 0)` | meta[1][0]=h2(k1); slot 0 now visible |
| 6 | `MCIterAdvanceYield(t1)` | yields k1 from slot 0; **seenKeys=⟨k1⟩**; iterIdx=1 |
| 7 | `MCRemove(t1, k1, 1, 0)` | slot 0 → NULL/TOMBSTONE |
| 8 | `MCInsertCASEntry(t1, k1, v1, 1, 1)` | k1 reinserted in slot 1 (no live duplicate at this moment) |
| 9 | `MCInsertStoreMeta(t1, 1, 1)` | meta[1][1]=h2(k1); slot 1 visible |
| 10 | `MCIterAdvanceYield(t1)` | yields k1 from slot 1; **seenKeys=⟨k1, k1⟩**. |

The iterator yields key `k1` twice in a single iteration even though at every moment in time there is at most one live `k1` entry.

### Root Cause

`Iter::next` at `raw/mod.rs:2960-2998` advances `self.i` linearly through the snapshot table and yields whatever is at slot `self.i` when it inspects it. Each slot is loaded with `Acquire`, but there is no per-iter "already-yielded keys" set. Across the iteration's lifetime, keys can be removed from a slot the iter has passed and reinserted into a slot the iter has not yet reached.

This is a real consequence of the lock-free, snapshot-at-table-pointer iteration model. The published documentation says iter is a "weak snapshot" but does not explicitly call out the double-yield possibility.

### Affected Code

- `artifact/papaya/src/raw/mod.rs:1400-1419` — `HashMap::iter` snapshot
- `artifact/papaya/src/raw/mod.rs:2960-2998` — `Iter::next` per-slot advance
- API documentation around `HashMap::iter` and `HashMap::values`

### Recommendation

Two options, in order of cost:

1. **(Cheap, doc-only)** Add a doc warning to `HashMap::iter` explicitly documenting that the same key may be yielded more than once if the caller mutates concurrently. Round-2 modeling brief already flags this in CR-4.
2. **(Stronger guarantee)** Track yielded keys in the `Iter` struct and skip already-yielded keys (one-line `HashSet` filter at the cost of `O(n)` memory per Iter). Likely too expensive for the common case but useful as an `iter_unique` variant.

Per the spec the safety invariants `NoLostEntry`, `NoDuplicateEntry`, `ProbeChainIntegrity` are unaffected — this is purely a caller-visible API contract issue.

---

## Not Reproduced

| Bug Family | Config | Result |
|------------|--------|--------|
| MC-3 / Family 6 — Iter Weak Snapshot (key inserted into NEW root after iter-begin missed by snapshot) | `MC_hunt_iter_weak_snapshot.cfg` | **No violation.** BFS depth 13 (30 min, 195K distinct states) and simulation follow-up (190M states checked, 8.6M traces, 30 min sim_depth=100) both passed `IterWeakSnapshot`. The spec's `IterWeakSnapshot` formulation already handles the post-promote case via `iterTable[tid] \notin AllTables`, which is the documented "weak snapshot" carve-out. |
| MC-7 / Family 1 — Resize Race (concurrent insert+remove+copy at same slot) | `MC_hunt_resize_race.cfg` | **No violation** after spec fix. First BFS run reported a `NoLostEntry` violation but inspection showed it was a Case B spec issue (`CopyInsertToNext` could fire twice for the same source slot, double-counting `copiedCount` and letting `TryPromote` fire spuriously). After tightening `CopyInsertToNext` to also set the `COPIED` tag on the source (modeling the impl's chunk-claim discipline at mod.rs:2292), BFS exhaustively explored 4.7M distinct states to depth 23 with no errors. |
| MC-5 / Family 4 — Reclamation (chain-monotonicity violation reclaiming a still-reachable entry) | `MC_hunt_reclamation.cfg` | **No violation.** BFS exhaustively completed in 15 s (309K distinct states, depth 20). Spec models reclamation conservatively — the deferred-retire walk's chain monotonicity is preserved by the spec's lack of a "remove-from-chain" action that doesn't go through Promote. |

---

## Spec Modifications During Bug Hunting

One Case B fix was applied during hunting and re-verified:

- **CopyInsertToNext one-shot per source slot** (base.tla). The first hunt of `MC_hunt_resize_race.cfg` reported `NoLostEntry` violated. Inspection showed the spec allowed `CopyInsertToNext` to fire twice with the same `srcS` and different `dstS` (re-copying the same key) because the spec did not model the impl's per-chunk `claim.fetch_add` discipline that partitions slots across copy threads. Fix: the action now sets the `COPIED` tag on the source as part of the insert-to-next, which makes the precondition `~ HasTag(src, COPIED)` enforce the one-shot semantics. Trace validation re-passes for all 4 traces, and the resize_race re-hunt then completed exhaustively without violations.

The fix is documented in `changelog.md` under "Round 2 - Trace Validation / Round 2 - Model Checking".

---

## Reference Tables

### State-Space Coverage Per Hunt

| Config | BFS Result | Distinct States | Diameter | Sim Result |
|--------|-----------|-----------------|----------|-----------|
| `MC_hunt_parker_deadlock.cfg` | violation @ 5 states | — | 7 | n/a (bug found) |
| `MC_hunt_meta_overwrite.cfg` | violation @ 5 states | — | 11 | n/a (bug found) |
| `MC_hunt_iter_double_yield.cfg` | violation @ 10 states | — | 11 | n/a (bug found) |
| `MC_hunt_iter_weak_snapshot.cfg` | no violation, timeout | 195,964 | 13 | 190M states, 8.6M traces, no violation |
| `MC_hunt_resize_race.cfg` (after fix) | exhaustive — no error | 4,725,718 | 23 | n/a (BFS exhaustive) |
| `MC_hunt_reclamation.cfg` | exhaustive — no error | 309,172 | 20 | n/a (BFS exhaustive) |

### Convergence MC

`MC.cfg` (3 threads / 3 slots / 2 keys / 2 values / standard safety + structural invariants) ran 30 min BFS to depth 13 with 9.2M distinct states and no invariant violations.
