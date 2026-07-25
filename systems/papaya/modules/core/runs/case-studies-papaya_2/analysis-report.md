# Analysis Report: papaya — Lock-Free Concurrent HashMap (Round 2)

## Coverage Statistics

| Metric | Value |
|--------|-------|
| Total commits on master | 182 |
| Bug-fix commits analyzed | 30 (round 1) + 4 new (round 2) |
| GitHub issues scanned | 42 (round 1) + 12 new (round 2) |
| GitHub issues deeply read (full comments) | 42 + 12 |
| Confirmed bugs from issues | 7 + 1 (#89 capacity assertion) |
| Open / draft PRs reviewed | 7 (focus on caller-misuse vectors) |
| Core source files fully read | 12 (all .rs files) |
| Total LOC analyzed | ~6700 |
| Parallel subagents used (this round) | 4 |

This round's working tree is the `instrument/trace-harness` branch (commit `509d77a`),
detached from upstream master at `303fb14` (the parent of v0.2.4 release `b510b15`). The
core code matches v0.2.3 / v0.2.4 modulo a tiny clippy fix and added TLA+ trace
instrumentation. The `meta-overwrite` race window (insert_at line ≈1047) and the
parker-deadlock test scaffold (`tests/repro_parker_deadlock.rs`) are pre-existing
instrumentation.

---

## Phase 1 — Reconnaissance

### Codebase Structure (no significant change since round 1)

```
src/
├── lib.rs              (251 LOC)  — Crate root, exports, META_OVERWRITE_BUG_COUNT static
├── map.rs             (1669 LOC)  — Public HashMap/HashMapRef API
├── set.rs              (894 LOC)  — HashSet wrapper
├── serde_impls.rs      (218 LOC)  — Serde support
├── tla_trace.rs        (569 LOC)  — TLA+ trace emission (this branch only)
└── raw/
    ├── mod.rs         (3156 LOC)  — Core lock-free hash table (★)
    ├── alloc.rs        (233 LOC)  — Table memory layout & allocation
    ├── probe.rs         (43 LOC)  — Quadratic probing sequence
    └── utils/
        ├── mod.rs      (117 LOC)  — Guard wrapper, CachePadded
        ├── counter.rs   (61 LOC)  — Sharded atomic counter
        ├── parker.rs   (149 LOC)  — Thread parking for resize
        ├── stack.rs     (74 LOC)  — Lock-free append-only stack
        └── tagged.rs   (133 LOC)  — Tagged pointer operations
```

### Category Classification

**Category B (Concurrent / Lock-Free)** — sub-category **Concurrent Collections**.

Justification: The system is a lock-free open-addressing hash table with epoch-based
reclamation, tagged pointers for resize coordination, and CAS-based linearization
points. There is no message-passing protocol, no consensus, and no failure model in
the distributed-systems sense; the entire fault model is thread interleaving + CAS
+ parker. Per the prioritization table in `references/concurrent-analysis.md`,
concurrent collections invest in **5.7 Caller Misuse**, **5.6 ABA**, and **5.3 OOM
during resize**, with 5.1 Thread Interleaving as the universal headline.

### Resize Protocol (recap)

- Two modes: `Blocking` (all writers complete the resize before progress) and
  `Incremental` (writers each copy a chunk, entries get COPYING/COPIED/BORROWED
  tags, eventually root is CAS'd to next).
- 3-bit pointer tag: `COPYING(0b001)`, `COPIED(0b010)`, `BORROWED(0b100)`.
- Status atomic: `PENDING(0) → ABORTED(1) | PROMOTED(2)`, kept on the destination
  table's State.
- Parker: keyed by atomic-address; one parker per table.

---

## Phase 2 — Bug Archaeology

### Recent commits (since round 1, since 2025-Q1)

| Commit | Summary | Verdict |
|--------|---------|---------|
| `731fb45` | Round initial capacity to power-of-two (master, fixes issue #89) | Bug fix; precondition correctness |
| `0574e3e` | Enforce minimum entry alignment (already in round 1) | Already covered |
| `2514b84` | Remove 64-bit atomics for 32-bit support | Refactor; touches parker/counter |
| `303fb14` / `355f87c` | Silence clippy warnings | Cosmetic |
| `58dac23` / `3177b22` | Fix HashSet retain signature | Already covered |

No newly-merged correctness fix lands on core resize/copy/parker logic since round 1
beyond the capacity-rounding fix.

### Open PRs reviewed (round-2 focus on adversarial-caller hints)

| PR | Status | Adversarial signal |
|----|--------|-------------------|
| #76 `drain` | DRAFT | **HIGH** — author explicitly notes "could maybe lead to elements being seen twice" during resize. Owner: "you would have to block for individual elements to complete to avoid yielding them twice". Canonical iter+modify+resize bug family made concrete in code. |
| #77 `iter_mut` / `into_iter` | OPEN | `&mut self` signature *statically* prevents the obvious footgun. `into_iter` uses `ManuallyDrop::take` — new unsafe surface but isolated. |
| #93 `HashSet::retain &self` | OPEN | Loosens `retain` to `&self` — predicate-races-insert pattern (caller misuse). |
| #88 `parking_lot` | OPEN | Owner skeptical; possible parker-protocol regressions. |
| #92 `unpark correct parker on resize abort` | "MERGED" on specula-org fork | Not on upstream master — see Family 3 below. |
| #91 `power-of-two capacity` | MERGED | Already in master (b510b15). |
| #78 `low-level HashTable API` | DRAFT | Exposes raw IntoIter/IterMut, same surface as #77/#76. |

### GitHub issues newly verified (round 2)

| Issue | Title | Verdict |
|-------|-------|---------|
| #89 | Assertion failed: `len.is_power_of_two()` | **Confirmed precondition bug**, fixed by `731fb45`. Not a lock-free correctness issue (panics rather than corruption). |
| #85 | Subtle bug with non-std hashers | User error — third-party hashers use process-global state; not a papaya bug. |
| #94 | `HashSet::new()/HashMap::new()` slow under tokio/rayon | Performance; seize collector init cost. Not a correctness bug. |
| #87, #86 | Compute docs / serde formats | Documentation/feature requests. |
| #67, #65, #84, #82, #83, #66, #60 | Various API / design Q&A | Not bugs. |

**Net new confirmed bugs from issues this round: 1** (#89, capacity assertion — already
fixed upstream but noted for completeness).

---

## Phase 3 — Deep Analysis (Round 2 Findings)

This round targeted three under-modeled areas from round 1: adversarial caller
(iter+modify+resize), OOM during resize, and compute_with re-entry.

### Finding D2-1: Parker abort-unpark targets WRONG parker — STILL UNFIXED on master

**Severity**: HIGH (deadlock, blocking-mode only, rare-but-real conditions).
**Status**: PR #92 (specula-org fork) proposed a fix; upstream master `b510b15`
does NOT contain it.

`raw/mod.rs:2282-2283`:

```rust
let state = table.state();           // SOURCE table, not destination
state.parker.unpark(&state.status);
```

The aborting code stores `State::ABORTED` to `next.state().status` (line 2268, the
destination's status), but unparks the SOURCE table's parker keyed on the SOURCE
table's status atomic. Threads parked at lines 2350-2352 (waiting for promotion of
`next`) are parked on `next.state().parker` keyed by `&next.state().status`. They
will never receive this wake-up — there is no other code path that unparks them
on abort. They will only unblock if a *future* `try_promote` of `next` happens
to wake them, which by definition won't happen for an aborted next table.

This is the same bug as round-1 finding D-4. The repro test
`tests/repro_parker_deadlock.rs` exists in the codebase and (with `papaya_stress`)
deadlocks. Liveness-checkable in TLA+.

**Mitigating factors**: The recovery path checks `Acquire`-loaded status *before*
each park attempt (line 2320, 2520) and the SPIN_WAIT spin window provides a
chance to observe ABORTED before parking. However, an unlucky scheduling that
parks the thread *before* the `SeqCst` ABORTED store becomes visible to it is
sufficient to deadlock the parker.

### Finding D2-2: Iter/Linearize is NOT a snapshot — caller-misuse hazard

**Severity**: MEDIUM (correctness divergence from naive expectation; documented vaguely).

`raw/mod.rs:1400-1419` (`iter()`) calls `linearize(root, guard)`
(`raw/mod.rs:2828-2843`). `linearize` only loops while the *current* table has a
`next_table()` and helps copy until promotion. After `linearize` returns, the
returned `table` may BE the new root, but as soon as `iter::next()` starts
scanning, a concurrent insert can:

1. Trigger a fresh resize on the (now non-root) table the iter holds.
2. Allocate a next-next table.
3. Copy entries into it.
4. Insert NEW keys directly into the new root.

The iter's `table` pointer is captured *by value* (line 1419) and held for the
iter's lifetime. Iter::next at lines 2961-2998 does not check tag bits — it
simply skips empty/tombstone metadata and returns whatever entry pointer is
currently in the slot. Consequences:

- **Missed entries**: Keys inserted after `iter()` started, into a table the iter
  doesn't see, are silently missed. (This is documented as "weak snapshot" in
  the public docs at `lib.rs:81`, but the API surface does not warn the caller
  that iter+resize is silently lossy.)
- **Ghost entries**: An entry that was COPIED away to next table can have its
  source slot overwritten *only* by EMPTY/TOMBSTONE meta or by a same-key new
  insert, so the iter still sees the old entry pointer (which is still alive
  via the guard). No double-yield in this case (the same-key case requires a
  full re-insert which will hit a different slot in the next table, but the
  iter holds the old table). Empirically: no double-yield from a single-table
  iter, but cross-table inconsistency is possible.

This is the classical caller-misuse / iter+modify+resize pattern from
`concurrent-analysis.md` § 5.7. Model-checkable: a TLA+ harness with
non-deterministic interleaving of `Iter.Begin → Iter.Next* → Iter.End` against
`Insert / Remove / Resize` would expose missed-key behavior, and the spec can
either prove the documented "weak snapshot" or pin down which writes can/cannot
be missed.

### Finding D2-3: Drain (PR #76) reveals iter+modify+resize hazard symbolically

**Severity**: HIGH if merged, currently DRAFT.

The PR's draft `drain` (`&self`) demonstrates exactly the bug class concurrent
collections analysis flags: an entry skipped on the source-table side because
it's COPYING can later be visited on the destination-table side, **double-
yielding** (and double-removing) the same key. The PR author and owner both
flagged this on the PR thread.

This is a useful test case for the spec: even though `drain` is not currently
in the public API, the underlying `iter+modify+resize` hazard already exists.
The model can express this as **exactly-once-iteration under concurrent
copy** — a property that the existing iter satisfies trivially (iter only
sees one table view) but that drain (or any iterator that follows next_table()
chains) would violate.

### Finding D2-4: META_OVERWRITE race on slot recycling — confirmed bug, instrumented

**Severity**: MEDIUM (slot leak / probe-chain bloat; degraded but not unsafe).

`raw/mod.rs:1014-1111` `insert_at`:

- Winner path (line 1046-1051): after CAS publishes entry pointer, stores meta
  byte = h2(key) at line 1051.
- Loser/fixup path (lines 1106-1108): a different inserter that sees the slot
  is non-empty and computes h2 of the existing key may also store meta = h2 if
  it observes meta still EMPTY.

The race: T1 wins CAS but stalls before the meta store. T2 (also inserting
same key) sees the entry, computes h2, takes the fixup path, writes meta = h2.
T3 reads meta = h2, finds key match, removes the entry, writes meta = TOMBSTONE.
T1 wakes and writes meta = h2 — overwriting the TOMBSTONE.

Consequences:
- `meta::TOMBSTONE` (0xFF) is the only value that signals "slot reusable" to a
  subsequent inserter (`raw/mod.rs:1316, 2973`: `matches!(meta, EMPTY|TOMBSTONE)`).
  Overwriting TOMBSTONE with h2 means that slot is no longer recyclable until a
  full-table copy.
- Probe-chain bloat: subsequent probes for h2-matching keys will load the slot's
  entry (now actually null/tombstone), skip via `entry.ptr.is_null()` check, and
  continue. Probe length grows by one for that bucket.
- Not a memory-safety bug (every code path that loads the slot re-checks the
  entry pointer). Not a correctness bug for `get`/`remove` semantics. **A
  liveness/throughput bug** for sustained insert-remove churn at the same key.

The repro test `tests/repro_bug1_meta_overwrite.rs` and the
`META_OVERWRITE_BUG_COUNT` static (`lib.rs:250`) confirm reproducibility; the
yield-loop instrumentation at line 1047 widens the window. Model-checkable: a
spec that explicitly models the meta byte and the slot recycling rule
(`InsertReclaimsTombstone`) would detect this.

### Finding D2-5: OOM is "abort-the-process"; no graceful degradation, no parked-thread leak

**Severity**: LOW (acceptable design, but worth recording).

- `Table::alloc` (`raw/alloc.rs:74`): on null from `alloc::alloc_zeroed`, calls
  `alloc::handle_alloc_error` which **aborts the process**.
- `init` (`raw/mod.rs:2048`) and `get_or_alloc_next` (`raw/mod.rs:2166`)
  delegate to `Table::alloc` and inherit abort-on-OOM semantics.
- `insert_inner`'s `Box::new(Entry { key, value })` (line 480): a panicking
  allocator unwinds; key/value are dropped via Rust's drop glue **before any
  map state has been mutated**. Map remains consistent.
- `compute_with`'s `LazyEntry::init` (line 1545-1566): explicitly wraps
  `Box::new` in `panic::catch_unwind` and aborts on panic, because the prior
  `ptr::read(key)` already moved the key out of the LazyEntry.

There is no graceful "OOM during resize" path: the process always aborts.
Therefore no half-migrated tables, leaked entries, or stuck parker waiters —
the abort takes everything down. This is the design choice. Not a bug.

For the modeling brief: 5.3 OOM-during-resize is not productive to model in
TLA+ for papaya, because the implementation's recovery is "abort". The spec
would have nothing to verify other than "process aborts" which is not a
state-space property.

### Finding D2-6: compute_with closure re-entry is allowed but not bounded

**Severity**: LOW (semantic surprise; not a memory-safety bug).

`compute` API (`raw/mod.rs:1697-1727`) allows the user closure to make
arbitrary calls back into the map (different keys). The closure may be invoked
multiple times for the same `Some(entry)` input across retries (e.g. when a
concurrent update changes the entry pointer or the entry is COPYING). The
docstring at line 1697-1699 only guarantees `compute(None)` is invoked at most
once.

Re-entry from the closure can:
- Trigger a resize that promotes the table the outer call holds, making its
  `table` snapshot stale.
- Cause subsequent loop iterations to advance via `prepare_retry` /
  `prepare_retry_insert`, potentially calling the closure again with a fresh
  `Some(entry')` from the new table.

No memory-safety implication: every loaded entry pointer is `guard.protect`-
ed and is valid for the guard's lifetime. The cached `state.update` keyed by
input pointer prevents redundant invocation when the same pointer is observed
again. But user closures with side effects may observe more invocations than
expected.

Not a TLA+-modeling target by itself; it is a documentation / API contract
issue.

### Finding D2-7: Counter sum() saturating-to-zero on transient negatives

**Severity**: LOW (by design; not a safety bug).

`raw/utils/counter.rs:51-60`: shards are AtomicIsize, summed and `try_into::<usize>`
falls back to 0 on negative. Comment at lines 57-59 acknowledges. Per-shard
fetch_add/fetch_sub use Relaxed. Different threads insert/remove from different
shards (sharded by guard thread_id at line 44), so a remover thread can drive its
own shard arbitrarily negative without ever inserting.

`HashMap::len()` may return 0 transiently for a non-empty map, or any
under-count. This is a documented design choice; the count is used for resize
heuristics (grow/shrink decision) and is approximate. Not a correctness bug.

### Finding D2-8: Stack push uses Relaxed CAS; safe due to seize discipline

**Severity**: LOW (subtle but correct).

`raw/utils/stack.rs:31-57` `Stack::push` uses Relaxed CAS for both load and
swap. The Node value is published by Relaxed CAS, which on weak memory
architectures is insufficient for the consumer to observe the write to
`Node.value`. However, `Stack::drain` requires `&mut self` (line 60), and
drain is called *only* from `drop_table` (`raw/mod.rs:3102-3115`), which is
called via `seize::Collector::retire` after all guards holding the table have
expired. Seize's epoch advance provides the synchronization edge between push
and drain. So the Relaxed CAS is correct in this design — but fragile to
future refactors.

Not a bug; recorded for completeness.

### Finding D2-9: defer_retire walk relies on next_table monotonicity

**Severity**: LOW (subtle but correct under current invariants).

`raw/mod.rs:2925-2935`: when an entry is being retired from a non-root table
deeper in the chain, the code walks from `root` forward (via `next_table()`)
looking for the table with `next.raw == table.raw`. If the walk reaches a table
without a `next_table()`, the `unwrap()` at line 2926 would panic.

The invariant relied upon: once a `next_table` link is installed, it is never
removed; the link list is append-only. This is true today (only the table
itself is deferred-retired, not the link state). But the walk takes `root` as
its starting point at line 2905 (which is itself loaded via `guard.protect`),
and if a concurrent promotion advances the actual root pointer, the walk's
`root` may be a stale snapshot. Since older tables are still reachable via
the guard, this is safe — but if any future change ever shortens the chain
(e.g. coalescing nested tables), this `unwrap` becomes a panic.

Not a current bug; modeling target is the chain-monotonicity invariant.

---

## Updated Bug Family Summary

| Family | Round-1 mechanism | Round-2 additions | Priority |
|--------|-------------------|-------------------|----------|
| 1: Resize copy/insert race | 9 historical, 2 D-findings | None new | **HIGH** |
| 2: Memory ordering gaps | 4 historical | None new | High |
| 3: Parker/wakeup deadlock | 3 historical + D-4 | **D2-1: confirmed STILL unfixed on master** | **HIGH** |
| 4: Reclamation safety | 5 historical | D2-8/9 (stack relaxed, defer-retire walk) | Medium |
| 5: Tagged pointer misuse | 3 historical | None new | Low (not modelable) |
| 6 (NEW): Caller-misuse / iter+modify+resize | n/a | D2-2, D2-3 | **HIGH** |
| 7 (NEW): Slot recycling / META overwrite | round-1 D-1 trade-off | D2-4 (confirmed instrumented) | Medium |
| 8 (NEW): OOM | n/a | D2-5 | Skip (abort-on-OOM design) |
| 9 (NEW): compute_with re-entry | n/a | D2-6 | Doc-only |

---

## Excluded findings (false positives / accepted designs)

| Finding | Why excluded |
|---------|--------------|
| Counter sum() returns 0 transiently | Documented; resize heuristic only |
| Stack::push Relaxed CAS | Sound under seize-guard discipline; not a current bug |
| compute_with closure may be invoked multiple times | Documented contract; not a safety bug |
| OOM aborts process | Acceptable deployment choice; nothing for TLA+ to verify |
| Iter sees stale table | Documented as "weak snapshot"; spec should record formally |
| insert_copy meta-fixup race | Cannot overwrite a published h2 (only EMPTY → h2); benign |
| try_promote relaxed root pre-check | Subsequent CAS provides safety; pre-check is optimization |
| Iter returning COPIED-tagged entries | Entry box is alive while guard held; safe |

---

## Round-2 Coverage Compared to Previous

| Bug family from prompt | Coverage |
|-----------------------|----------|
| Caller misuse (iter+modify+resize) | **Covered** — D2-2, D2-3 |
| OOM during resize | **Covered, excluded from modeling** — D2-5 (abort-on-OOM) |
| Parker / unpark routing | **Covered, BUG STILL PRESENT** — D2-1 |
| ABA / slot reuse on probe sequence | Covered indirectly — D2-4 (meta overwrite is the slot-recycling instance) |
| Memory ordering on meta + entry publication | Covered round-1 + D2-4 |
| compute_with re-entry | **Covered** — D2-6 |

The two prompt-flagged gaps (caller-misuse, OOM) are now addressed; OOM is
excluded with rationale. Parker D-4 promoted to D2-1 and confirmed STILL
unfixed in upstream master — primary modeling target.

---

## Reference Pointers

- Code: `/home/ubuntu/Specula/case-studies/papaya_2/artifact/papaya/src/raw/mod.rs` and `raw/alloc.rs`, `raw/utils/*`
- Round-1 brief: `/home/ubuntu/Specula/case-studies/papaya/modeling-brief.md`
- Round-1 report: `/home/ubuntu/Specula/case-studies/papaya/analysis-report.md`
- Repro tests: `tests/repro_bug1_meta_overwrite.rs`, `tests/repro_parker_deadlock.rs`
- Primary GitHub references: PR #76 (drain hazard), PR #77 (iter_mut), PR #92 (parker fix not on master), issue #89 (capacity assertion)
- Tracking: master = `b510b15` (release 0.2.4); analyzed code = `509d77a` (instrument/trace-harness branch ≈ v0.2.3 + clippy + trace instrumentation)
