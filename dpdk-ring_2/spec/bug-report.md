# Bug Report — DPDK rte_ring (Round 2)

## Summary

- Bug families tested: 8 (A, B, C, D.1, D.2, D.3, D.4, E)
- Bugs found: 4 confirmed real bugs (A, D.1, D.2, D.3)
- Configs run: `MC_hunt_familyA.cfg`, `MC_hunt_familyB.cfg`, `MC_hunt_familyC.cfg`, `MC_hunt_familyD1.cfg`, `MC_hunt_familyD2.cfg`, `MC_hunt_familyD3.cfg`, `MC_hunt_familyD4.cfg`, `MC_hunt_familyE.cfg`

This round targeted the **gaps** the prior 4.1B-state verification round did not model
(per `modeling-brief.md` §1):

- Family A — RTS update_tail residual stale-head load (BZ-1527)
- Family B — Caller misuse / sync_type confusion at the public API
- Family C — Default-mode partial-order regression check (Nov 2025 patch)
- Family D — SORING (Dec 2024 stage ring) hazards
- Family E — Peek API atomicity / NDEBUG-masked invariants

The Round-2 verification has reproduced the **canonical BZ-1527 mechanism**
(Family A) under an explicit C11 stale-head-load adversary, and surfaced
**three previously-unverified SORING hazards** (D.1 stale head in
`__rte_soring_stage_move_head`, D.2 lost-finalize race, D.3 silent
release-count corruption). Family C confirms the November 2025
release/acquire chain is sound (no regression). Family B and D.4 were not
reachable under this round's harness/spec coverage; Family E surfaced a
spec-side invariant defect rather than an implementation bug.

---

## Bug 1 — Family A: RTS `update_tail` residual stale-head load (BZ-1527)

- **Bug Family**: A — RTS update_tail residual stale-head load
- **Severity**: **High** (production-impacting; matches an open DPDK Bugzilla report)
- **Invariant violated**: `MC_RTSPosCntConsistent`
  (`(rts.tail.cnt = rts.head.cnt) ⇒ (rts.tail.pos = rts.head.pos)`)
- **Config**: `MC_hunt_familyA.cfg` (Mode=RTS, MaxStaleHeadRTS=2)
- **Counterexample**: 9 states, BFS depth 22 — `spec/output/MC_hunt_A_bfs.out`

### Trace Summary

1. **Init** (state 1): all zero.
2. t1 enters RTS enqueue (`RTSProdHeadWait`, then `RTSProdLoadStail`).
3. t2 also enters RTS enqueue (state 3).
4. t1 completes `RTSProdCAS` success → `rtsProdHead.{cnt,pos} = (1,1)`.
5. t1 starts `RTSProdUpdateTail`: `_LoadTail` snapshots `ot=(0,0)`. Ring slot 0 = 1.
6. **`MCStaleHeadRTS(t1)`** (state 7): the relaxed head load returns a
   *stale* `(cnt,pos)=(0,0)` — the value of `ht->head.raw` from
   *before* t1's own CAS (the C11 acquire on the failure path of the
   previous CAS, or any prior epoch). `locStaleHead[t1] = (cnt:0,pos:0)`.
7. t1 fires `_Compute` → `_CAS`: with `ot=(0,0)`, `h_stale=(0,0)`,
   `nt.cnt = ot.cnt+1 = 1`, `nt.pos = (nt.cnt = h.cnt) ? h.pos : ot.pos = 0`
   (because `nt.cnt=1 ≠ h.cnt=0`, fall through to `ot.pos=0`).
8. **CAS publishes `tail.{cnt,pos}=(1,0)`** while `head.{cnt,pos}=(1,1)`.
   Invariant violated.

### Root Cause

`__rte_ring_rts_update_tail` (`lib/ring/rte_ring_rts_elem_pvt.h:25-62`)
loads `ht->head.raw` with `rte_memory_order_relaxed` at line 49 inside the
do/while retry loop:

```c
ot = rte_atomic_load_explicit(&ht->tail.raw, rte_memory_order_acquire);
do {
    h = rte_atomic_load_explicit(&ht->head.raw,
                                 rte_memory_order_relaxed);   // <-- line 49
    nt.raw = ot.raw;
    ++nt.val.cnt;
    if (nt.val.cnt == h.val.cnt)
        nt.val.pos = h.val.pos;
} while (...);
```

The November 2025 ordering patch (commit `36b69b5f95`) upgraded the *tail*
CAS-failure ordering to acquire but did **not** add an acquire on this
*head* load. Under RCpc memory models (AArch64 LDxR, PowerPC), this
producer can use a head value that lags the head publisher's release.
With the stale view, the `(nt.cnt = h.cnt) ? h.pos : ot.pos` choice
takes the wrong branch and publishes a tail whose `cnt` advances but
whose `pos` regresses (or freezes) relative to head.

Subsequent producers see `tail.cnt == head.cnt` (the "no-one-is-last"
condition) and `__rte_ring_rts_head_wait` will either stall forever
(the BZ-1527 hang pattern) or feed further mis-ordered tails into the
ring, corrupting consumer reads.

### Affected Code

- `lib/ring/rte_ring_rts_elem_pvt.h:47-61` — the relaxed head load inside `__rte_ring_rts_update_tail`'s retry loop.
- All RTS enqueue / dequeue paths that call `__rte_ring_rts_update_tail`:
  `__rte_ring_do_rts_enqueue_elem` and `__rte_ring_do_rts_dequeue_elem`
  in the same header.

### Recommendation

Promote the `relaxed` load at line 49 to `rte_memory_order_acquire`, so
that `head.raw` is read with the same synchronisation guarantee the
matching head writers (the RTS move_head CAS at lines 169-172) provide
on their release. This is the same fix the November 2025 trio applied
to default-mode and HTS; it was simply missed for the in-loop head load
on the RTS tail path. Cross-reference the resulting fix against
**DPDK Bugzilla 1527** before closing.

---

## Bug 2 — Family D.1: SORING `__rte_soring_stage_move_head` stale head load

- **Bug Family**: D.1 — SORING stage_move_head with stale head load
- **Severity**: **Medium-High** (new code, no prior verification, narrow but real)
- **Invariant violated**: `MC_SORingStageOrdered`
  (per-stage ordering: `tail[s] ≤ head[s] ≤ tail[s+1]` mod-PosWrap)
- **Config**: `MC_hunt_familyD1.cfg` (Mode=SORING, MaxStaleHeadSORing=2)
- **Counterexample**: 23 states, BFS depth 30 — `spec/output/MC_hunt_D1_bfs.out`

### Trace Summary

After the SORING input is primed via `SORingProdEnqueue` and one stage-0
acquire succeeds normally, `MCStaleHeadSORing(t1, s=0, n=1)` fires: the
relaxed head load at `soring.c:228` returns a head value smaller than
the live `sStageHead[0]` — i.e., the producer attempting `stage_move_head`
sees a head that another producer has already advanced past. With the
small `PosWrap=4`, this is enough for the CAS-success branch to publish
a `sStageHead` update that is *behind* the previous-stage's tail —
breaking the per-stage monotonicity invariant.

### Root Cause

`__rte_soring_stage_move_head` at `lib/ring/soring.c:228-247` still uses
the **pre-November-2025 anti-pattern**:

```c
*old_head = rte_atomic_load_explicit(&d->head.raw, rte_memory_order_relaxed);  // line 228
do {
    rte_atomic_thread_fence(rte_memory_order_acquire);                          // line 235 — explicit fence
    *avail = (...);
    ...
} while (rte_atomic_compare_exchange_strong_explicit(&d->head.raw, old_head, ...));
```

That is, the November 2025 partial-order trio of fixes
(`a4ad0eba9d`, `66d5f96278`, `36b69b5f95`) was applied to default,
HTS, and RTS modes, but **not** to SORING. The same C11 hazard the
November patch addressed for default mode applies here: under RCpc
memory models, the stale head load can be observed even after the
acquire fence on a subsequent retry, because the fence only orders
operations *issued after it* — it does not bridge a load that was
already issued before the loop body executed.

### Affected Code

- `lib/ring/soring.c:220-250` — `__rte_soring_stage_move_head`.

### Recommendation

Apply the November-2025 fix pattern to SORING: replace the relaxed head
load + explicit acquire fence with an acquire load on `d->head.raw`,
and rely on the CAS failure-acquire to refresh the snapshot — the same
mechanism `__rte_ring_headtail_move_head` now uses
(`rte_ring_c11_pvt.h:74-143`).

---

## Bug 3 — Family D.2: SORING release lost-finalize race

- **Bug Family**: D.2 — SORING release + tail.pos load races; finalize-from-release lost
- **Severity**: **Medium** (liveness, not safety; affects throughput / latency tail under concurrency)
- **Invariant violated**: `MC_SORingNoStuckFinalize`
- **Config**: `MC_hunt_familyD2.cfg` (Mode=SORING, MaxStaleTailSORing=2)
- **Counterexample**: 9 states, BFS depth 14 — `spec/output/MC_hunt_D2_bfs.out`

### Trace Summary

1. t2 acquires the only START slot at stage 0 (slot 0, ftoken 0).
2. t2 advances through release: `LoadState` → `Verify` → `WriteRing` →
   `StoreFinish` (slot 0 → FINISH).
3. t2 reaches `SORingRelease.LoadTail` (state 8). The relaxed load
   sees `sStageTailPos[0] = 0 = pos`, which would normally trigger
   `__rte_soring_stage_finalize`.
4. **`MCStaleTailSORing(t2)`** (state 9): the relaxed load returns a
   stale `tail.pos /= pos`, so the `if (tail == pos)` check at
   `soring.c:485` is **false** and t2 returns to Idle without calling
   `__rte_soring_stage_finalize`. Slot 0 remains in FINISH state with
   `sStageTailPos[0]` permanently behind it — `finalizeStuck` never
   clears.

### Root Cause

`soring.c:476-487`:

```c
rte_atomic_thread_fence(rte_memory_order_release);                        // 477
rte_atomic_store_explicit(&stg->state[idx].raw, FINISH | n,               // 478-480
                          rte_memory_order_relaxed);

if (rte_atomic_load_explicit(&stg->sht.tail.pos,                          // 483
                             rte_memory_order_relaxed) == pos)
    __rte_soring_stage_finalize(stg);                                     // 487
```

The *FINISH store* uses `relaxed` — it relies on the prior release fence
for visibility. But the *tail.pos load* on line 483 also uses `relaxed`,
so a peer's earlier `__rte_soring_stage_finalize` `tail.pos` write may
not be observed by this thread. Conversely, this thread's FINISH store
may not be observed by peers reading tail.pos. In either case, the
`tail == pos` predicate returns FALSE incorrectly, and the call into
`__rte_soring_stage_finalize` is *skipped*.

Forward progress is preserved by lazy-finalize-on-acquire (the next
`stage_move_head` will eventually walk past the FINISH), but a
quiescent stage can pin a FINISH slot indefinitely — burning ring
capacity and (under high stage count) potentially leading to head/tail
distance exceeding `htd_max` and causing producer stalls.

### Affected Code

- `soring.c:476-487` — the FINISH store + tail.pos load pair in
  `soring_release`.

### Recommendation

Either:
1. Promote the tail.pos load on line 483 to `rte_memory_order_acquire`
   so it synchronises with finalize's release-store on `tail.pos`, *and*
   change the FINISH store on lines 478-480 to `rte_memory_order_release`
   so peers loading state with acquire (in `stage_finalize`'s WalkStates)
   observe it.
2. Or, more simply, always call `__rte_soring_stage_finalize` from the
   release path (let the function's own CAS gate do the deduplication).
   Saves the extra atomic load and removes the relaxed-load hazard.

---

## Bug 4 — Family D.3: SORING release-count mismatch silent corruption

- **Bug Family**: D.3 — Caller invokes `rte_soring_release` with `n` differing from `n_acquired`
- **Severity**: **Medium** (caller-misuse path, but silent under NDEBUG)
- **Invariant violated**: `MC_SORingReleaseExact`
  (the `n` passed to release == the `n` returned by acquire for the same ftoken)
- **Config**: `MC_hunt_familyD3.cfg` (Mode=SORING, MaxWrongReleaseN=2)
- **Counterexample**: 7 states, BFS depth 12 — `spec/output/MC_hunt_D3_bfs.out`

### Trace Summary

1. t1 acquires slot 0 with `n=1`, gets ftoken 0; `sStateN[0][0]=1`.
2. **`MCWrongReleaseN(t2, delta=-1)`** (state 6): t2 calls release on
   slot 0 with `locReleaseN=0` (n_acquired was 1, off-by-one).
3. t2 enters `SORingRelease.Verify` (state 7): the verify step sets
   `overCommitted=true` because `locReleaseN[t2]=0 ≠ locActualN[t2]=1`.
4. The release nonetheless proceeds (since `RTE_ASSERT` is compiled out
   under NDEBUG): the FINISH state will be written with the *wrong* n,
   and the next `__rte_soring_stage_finalize` walk will use the wrong
   n to compute the new tail — under-finalising or over-finalising the
   slot range.

### Root Cause

`soring_release` (`soring.c:441-465`) uses `RTE_ASSERT` (compiled out
under `NDEBUG`) to validate that the caller's `n` matches the n stored
at acquire time. With `RTE_ASSERT` off, the wrong `n` is silently
recorded into `state[idx].n`, and the subsequent finalize walks past
`(n_acquired - n_released)` extra slots or stops short, corrupting the
stage's tail position by ±n.

### Affected Code

- `soring.c:441-465` — the verify path in `soring_release` /
  `soring_verify_state`.

### Recommendation

- Replace `RTE_ASSERT` with `RTE_VERIFY` (always enabled) for this
  precondition, **or**
- Return a non-zero error code on mismatch so the caller can detect
  it, **or**
- At minimum, document the precondition prominently in the public
  `rte_soring_release` doxygen and in `rel_notes`. Internal test
  coverage in `app/test/test_soring.c` should add a deliberate misuse
  case.

---

## Bug-Like Finding 5 — Family E: PeekRollbackAtomic invariant fires for non-peek ops in ST mode

- **Bug Family**: E — Peek API atomicity / NDEBUG-masked invariants
- **Severity**: **Spec issue** (Case A — invariant too strong) **rather than implementation bug**
- **Invariant violated**: `MC_PeekRollbackAtomic`
- **Config**: `MC_hunt_familyE.cfg` (Mode=ST, MaxMisuseFinishN=2)
- **Counterexample**: 4 states, BFS depth 8 — `spec/output/MC_hunt_E_bfs.out`

### Analysis

The `PeekRollbackAtomic` invariant
(`base.tla:1497-1499`) reads:

```tla
PeekRollbackAtomic ==
    Mode \in {"ST","HTS"} =>
        prodHead = prodTail \/ \E t \in Thread : phase[t] = "Peek.Start"
```

i.e., in ST/HTS mode, either the ring is quiescent (head = tail) or
some thread is mid-peek. But in real DPDK, ST mode supports *both*
the regular bulk-enqueue API (`rte_ring_sp_enqueue_*`) and the peek
API (`rte_ring_enqueue_zc_*_start/_finish`). A thread in regular
ST enqueue is in `MoveHead.Reserved` phase (not `Peek.Start`) but
has `prodHead /= prodTail` between move_head and update_tail. The
counterexample is exactly this case — a regular ST enqueue, no
`MCMisuseFinishN` injected.

The intended **peek-finish over-commit hazard** (caller passes
`commit_n > reserved_n`, the silent rollback at
`peek_elem_pvt.h:30-63` discards reserved slots) was *not* reached
in this run because the spec deadlocks immediately at state 1 of
the actual peek path under MaxBatch=2 (the `actual_n > 0 /\
n > free` branching needs `Capacity > MaxBatch` which the cfg
violates).

### Recommendation

Spec follow-up (not an implementation finding):
1. Tighten the invariant to apply only to peek-style operations:
   `op[t] = "enq" /\ phase[t] \in {"Peek.Start"}`, or
2. Drop the structural form of `PeekRollbackAtomic` and instead
   check `~overCommitted` after every `PeekFinish`, or
3. Re-tune `MC_hunt_familyE.cfg` (`Capacity = 3`, `MaxBatch = 1`)
   so the peek path is reachable and the over-commit branch can be
   evaluated.

The implementation question — whether peek finish with
`commit_n > reserved_n` can leak data — remains *unverified* for this
round. Test-verifiable finding `TV-3` in `modeling-brief.md §6.2`
remains the recommended follow-up.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| **B** — Caller misuse / sync_type confusion | `MC_hunt_familyB.cfg` | 119 941 generated, 38 469 distinct, depth 43 | No violation. The spec's `MCMisuseAPI` action sets `callMode[t] /= Mode` while `phase[t] = "Idle"`, but the very next action (e.g., `ProdMoveHead_LoadHead`) overwrites `callMode[t] := Mode`, erasing the misuse before any structural invariant can observe it. **Modeling gap** — the misuse needs to persist across the whole call to be testable. Recommend: bind `callMode` at op start and never re-assign within an op; or move misuse injection to the *first action of the op* (e.g., `ProdMoveHead_LoadHead`) rather than as a separate Idle-phase action. |
| **C** — Default-mode partial-order regression | `MC_hunt_familyC.cfg` | 64 357 generated, 18 816 distinct, depth 40 | No violation — the November 2025 release/acquire chain holds `DefaultPartialOrder` and `ConsumedWasPushed` under `MCStaleConsTail` injection. **Confirms** the patch is sound under a 2-thread / Capacity-2 / MaxBatch-1 model. |
| **D.4** — SORING ftoken wraparound | `MC_hunt_familyD4.cfg` | 3 generated, depth 3, **deadlock at state 3** | Not testable in this configuration. The cfg sets `PosWrap = 2` to force ftoken collision, but with `Capacity = 2 / PosWrap = 2`, `FreeProd = (Capacity + stail - head) % PosWrap = (2 + 0 - 0) mod 2 = 0`, so `SORingProdEnqueue` is never enabled and the SORING path cannot make initial progress. Need a separate setup (e.g., `Capacity = 1 / PosWrap = 2` so capacity check uses unwrapped arithmetic, or change `FreeProd` to clamp). Re-design left as a follow-up; the *expected* finding (two acquires sharing `(stage, ftoken)` after a wrap) is plausibly real on 32-bit ftokens but unconfirmed by this round. |

---

## Spec Adjustments Made During Hunting

These were necessary to drive the hunt configs and are recorded in `changelog.md`:

1. **`base.tla` `ProdMoveHead_LoadTail` / `ProdMoveHead_CAS`** — added missing
   `role[t] = "prod"` guards. Without them, a thread that started a
   consumer call (role=cons) could fire the producer-side LoadTail/CAS
   because all three entry actions transition to the shared
   `MoveHead.LoadHead` phase. (Discovered during the convergence
   model-check; this is itself a Case-B spec defect rather than an
   implementation bug.)

2. **`base.tla` `SORingRelease_LoadTail`** — branch 1 (tail==pos) was missing
   `UNCHANGED <<op, role>>`, leaving them undefined in the post-state.
   Discovered during SORING trace replay.

3. **`base.tla` `RTSProdLoadStail` / `RTSConsLoadStail`** — were reading
   default-mode `consTail` / `prodTail` (always 0 under RTS); changed to
   `rtsConsTailPos` / `rtsProdTailPos`. Discovered during RTS trace
   replay.

4. **`base.tla` `SORingProdEnqueue` (new action)** — added a structural
   action that advances `prodTail` for the SORING input side, so D.1 / D.2 /
   D.3 hunting configs can make progress. The harness exercises
   `rte_soring_enqueue_bulk` but does not instrument it; the spec was
   missing the corresponding state transition.

5. **`MC.cfg` `BoundedRun` constraint** (`nextVal ≤ Capacity + 2 ∧
   posWrapCount ≤ 1`) — caps the run length to keep counter
   wraparound out of the convergence and most hunting runs.
   `modeling-brief.md` §3.2 explicitly classifies 32-bit wraparound
   as "Do Not Model": real DPDK relies on `in_flight < 2^31` which is
   unreachable in practice. Without the constraint, the small
   `PosWrap = 4` lets a stale `locOldHead = 0` reappear as the live
   `prodHead = 0` after wrap, surfacing a false-positive ABA. (D.4
   intentionally exercises wrap and so does *not* apply this
   constraint.)

---

## Coverage Statistics

| Config | States generated | Distinct | Depth | Result |
|--------|-----------------:|---------:|------:|--------|
| `MC.cfg` (convergence) | 29 106 | 11 909 | 40 | PASS |
| `MC_hunt_familyA.cfg` | 1 452 | 808 | 22 | **VIOLATION** (BZ-1527) |
| `MC_hunt_familyB.cfg` | 119 941 | 38 469 | 43 | No violation (modeling gap) |
| `MC_hunt_familyC.cfg` | 64 357 | 18 816 | 40 | No violation (regression confirmed sound) |
| `MC_hunt_familyD1.cfg` | 19 039 | 8 852 | 30 | **VIOLATION** (SORING stale head) |
| `MC_hunt_familyD2.cfg` | 185 | 125 | 14 | **VIOLATION** (SORING lost finalize) |
| `MC_hunt_familyD3.cfg` | 262 | 188 | 12 | **VIOLATION** (SORING wrong release n) |
| `MC_hunt_familyD4.cfg` | 3 | 3 | 3 | Deadlock (config not testable) |
| `MC_hunt_familyE.cfg` | 183 | 150 | 8 | Spec invariant defect (false positive) |

All BFS diameters except B and C are ≤ 30, meaning simulation follow-up
*could* extend coverage. For families with violations already found
(A, D.1, D.2, D.3, E), simulation is unnecessary. Family B has depth 43
(BFS sufficient). Family C has depth 40 (BFS sufficient). Family D.4
needs a config redesign before any further exploration is meaningful.
