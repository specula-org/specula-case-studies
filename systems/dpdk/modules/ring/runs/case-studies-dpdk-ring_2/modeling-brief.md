# DPDK rte_ring — Modeling Brief (Round 2)

## 1. System Overview

- **System**: DPDK `lib/ring/` — lock-free MPMC bounded ring buffer with four sync modes (ST, MT, MT_HTS, MT_RTS) plus a new SORING (staged ordered ring) extension. C, ~6,914 LOC across 18 files.
- **System category**: **Category B (Concurrent / Lock-Free / Runtime)**, sub-category **lock-free data structures** (per `concurrent-analysis.md` §5 prioritisation table). In-process MPMC queue with split head/tail counters, no network I/O, no protocol state machine.
- **Algorithm**: classical Lamport-style split head/tail FIFO, with three multi-thread variants:
  - **MT (default)**: independent head CAS per side; tail published in order via spin-on-prior-tail.
  - **HTS**: 64-bit CAS on `(head, tail)` pair; producers/consumers fully serialised by waiting for `head==tail`.
  - **RTS**: counter-tagged head/tail; tail published only by the *last* in-flight producer; throttled by `htd_max`.
- **Key deviations** from a textbook MPMC: `htd_max` flow control in RTS; single 64-bit atomic for HTS pair; out-of-order tail publication in RTS.
- **Concurrency model**: per-thread program counters interact via `__atomic_*` ops with explicit C11 ordering. No locks on the data path. Three private headers (`rte_ring_c11_pvt.h`, `rte_ring_hts_elem_pvt.h`, `rte_ring_rts_elem_pvt.h`) implement the linearisation logic per mode.
- **Recent activity**: three coordinated fixes on **2025-11-11** (`a4ad0eba9d`, `66d5f96278`, `36b69b5f95`) addressing a documented C11 ordering hazard manifesting on AArch64 RCpc; SORING introduced 2024-12 (`b5458e2cc4`); LTO false-positive workaround 2026-02 (`66c348c208`).

**Prior verification round**: 4.1B states, 0 bugs, modelled `MCStall` / `MCStaleRead` / `MCRTSCaptureHead` for the SPSC/MPMC core under the *pre-Nov-2025* code. This round targets the **gaps** the prior round did not model.

## 2. Bug Families

### Family A: RTS update_tail residual stale-head load (BZ-1527 candidate)

**Mechanism**: in `__rte_ring_rts_update_tail`, the load of `ht->head.raw` inside the CAS retry loop uses `rte_memory_order_relaxed`. The Nov 2025 patch upgraded the *tail* CAS-failure ordering to `acquire`, but did not add an acquire/fence on the *head* load. Under RCpc (AArch64), a producer in update_tail may use a stale `h.cnt`/`h.pos` after a CAS-failure retry, leading to publishing `tail.{cnt=head.cnt, pos=stale}`. Subsequent producers see `tail.cnt == head.cnt` (no one is "last") and `__rte_ring_rts_head_wait` spins forever — matches BZ-1527's PowerPC hang pattern.

**Evidence**:
- Historical: BZ-1527 (open, IN PROGRESS) — Konstantin's diagnosis "head and tail .cnt are equal but .pos differ"; workaround `htd_max=0` bypasses the throttle. November 2025 patch did **not** explicitly close the BZ.
- Code analysis: `lib/ring/rte_ring_rts_elem_pvt.h:49` — `rte_atomic_load_explicit(&ht->head.raw, rte_memory_order_relaxed)` inside the do/while at lines 47-61. CAS-failure-acquire at line 61 synchronises with `tail.raw` writers, not `head.raw` writers.

**Affected code paths**: `__rte_ring_rts_update_tail` (rts_elem_pvt.h:25-62) called by all RTS enqueue/dequeue paths (`__rte_ring_do_rts_enqueue_elem`, `__rte_ring_do_rts_dequeue_elem`).

**Suggested modeling approach**:
- **Variables**: per-thread `local_h` snapshot in update_tail; explicit `head.cnt`, `head.pos`, `tail.cnt`, `tail.pos` (already in prior spec).
- **Actions**: split `RTSUpdateTail` into (a) load `ot` (tail acquire), (b) load `h` (head, stale or fresh — non-deterministic), (c) compute `nt`, (d) CAS. The (b) action models the missing acquire by allowing `h` to be any value previously written to `head.raw` that has not yet been observed by this thread. Reuse the prior round's `MCStaleRead` infrastructure.
- **Granularity**: 4 atomic actions per update_tail iteration, plus the existing move_head action set.
- **Invariant**: `(tail.cnt == head.cnt) ⇒ (tail.pos == head.pos)` — must hold whenever the ring is in a quiescent state.

**Priority**: **HIGH**. **Rationale**: an open production bug (BZ-1527) with a plausible mechanism this analysis identified; the Nov 2025 partial-order fix did not address this specific load; PPC and AArch64 RCpc deployment is realistic.

---

### Family B: Caller misuse / sync_type mode confusion at public API

**Mechanism**: the mode-specific public APIs (`rte_ring_mp_hts_enqueue_*`, `rte_ring_mp_rts_enqueue_*`) bypass the `r->prod.sync_type` switch that the generic dispatcher (`rte_ring_enqueue_bulk_elem`) uses. A caller that creates a ring with one sync type but invokes the wrong mode-specific API (or invokes it on a ring whose flags were misconfigured) silently corrupts state via layout-mismatched 64-bit CAS.

**Evidence**:
- Historical: `c8d909aeb7` (2020) "ring: fix bulk enqueue for HTS/RTS ring modes" — exactly this class of bug, where a code path skipped the sync_type switch and hit the wrong implementation. Already fixed once; the underlying API surface still allows direct misuse.
- Code analysis:
  - `rte_ring_hts.h:52-141` — `rte_ring_mp_hts_enqueue_*` directly call HTS implementations with no sync_type guard.
  - `rte_ring_rts.h:79-262` — same.
  - `rte_ring_elem.h:178-680` — generic dispatcher correctly uses `switch (r->prod.sync_type)`.

**Affected code paths**: every mode-specific public API in `rte_ring_hts.h`, `rte_ring_rts.h`, `rte_ring_peek.h`, `rte_ring_peek_zc.h`.

**Suggested modeling approach**:
- **Variables**: a `ClientHarness` action set above the library spec; `ring.actual_sync_type ∈ {ST, MT, RTS, HTS}`; `api.intended_sync_type` chosen non-deterministically per call.
- **Actions**: `MCMisuseAPI` — invoke an API whose intended sync_type does not match the ring's actual sync_type.
- **Granularity**: harness-level (above library boundary), per `concurrent-analysis.md` §5.7.
- **Invariant**: `api.intended == ring.actual` is a precondition; if the harness violates it, the spec should expose a violation of internal invariants (head/tail consistency, no double-enqueue, etc.).

**Priority**: **MEDIUM**. **Rationale**: this is the canonical "unmodelled fault family" called out in the target instructions. Real and deployment-relevant given DPDK's per-mode optimised callsites, but the dispatcher-level API correctly mitigates most production usage.

---

### Family C: Default-mode partial-order regression check

**Mechanism**: confirm the November 2025 default-mode patch (`a4ad0eba9d`) is faithful and the ordering chain is sound across the spec's actions.

**Evidence**:
- Historical: `a4ad0eba9d` commit message cites a Herd7 litmus test demonstrating the previous bug; "underflow in free-slot or available-element computations → potential data corruption" on AArch64 RCpc.
- Code analysis: `lib/ring/rte_ring_c11_pvt.h:74-143` — new pattern: load `*old_head` with acquire, CAS with release/acquire, no in-loop fence.

**Affected code paths**: `__rte_ring_headtail_move_head`, `__rte_ring_update_tail` (used by default MP/MC and SP/SC).

**Suggested modeling approach**:
- **Variables**: existing `head`, `tail` per side; per-thread `*old_head` snapshot.
- **Actions**: re-tag the load/store/CAS actions with C11 orderings; remove the now-redundant explicit fence action.
- **Adversary**: reuse `MCStaleRead` to verify that the new release/acquire chain is sufficient *without* the prior thread fence.
- **Invariant**: `cons.head ≤ cons.tail ≤ prod.head ≤ prod.tail (mod 2^32, in-flight < capacity)`; element-id consistency between enqueue and dequeue.

**Priority**: **HIGH** (regression protection). **Rationale**: confirms a production-critical fix; cheap to model given prior-round infrastructure.

---

### Family D: SORING — multiple concurrency hazards in new code

**Mechanism**: SORING (Dec 2024) is recently-added code with limited verification history. Multiple sub-findings:

- **D.1**: `__rte_soring_stage_move_head` (`soring.c:228-247`) still uses the **pre-Nov-2025** anti-pattern (relaxed head load + explicit acquire fence + acquire tail load). The same C11 hazard the November patch addressed for default mode applies here.
- **D.2**: `soring_release` (`soring.c:475-487`) stores FINISH with `relaxed` and immediately reads `tail.pos` with `relaxed`. Under weak memory models, the FINISH may be invisible to peers and the tail.pos may be stale → lost-finalize race. Forward progress is preserved by lazy-finalize-on-acquire, but quiescent stages can pin slots indefinitely.
- **D.3**: `soring_release` (`soring.c:441-465`) calls `soring_verify_state` which under non-debug builds **only logs**; a wrong `n` from caller corrupts the stage's tail by ±n.
- **D.4**: `SORING_FTKN_MAKE(pos, stg) = pos + stg` (`soring.h:48`) — 32-bit ftoken collides at `pos` wraparound (2^32 ops). No epoch counter.

**Evidence**:
- Historical: `b5458e2cc4` SORING introduction; `66c348c208` LTO build workaround (BZ-1864 / BZ-1726); SORING was *not* touched by the November 2025 partial-order trio of fixes.
- Code analysis: line citations above.

**Affected code paths**: `__rte_soring_stage_move_head`, `__rte_soring_stage_finalize`, `soring_release`, `soring_acquire`, `acquire_state_update`.

**Suggested modeling approach**:
- **Variables**: per-stage `head[s]`, `tail[s]`, `state[s][idx] ∈ {EMPTY, START, FINISH}`, `state[s][idx].ftoken`, `state[s][idx].n`. Per-thread program counter. Wrap counter for ftoken collision check.
- **Actions**: split each of `acquire`, `release`, `finalize`, `stage_move_head` into multi-step actions matching the implementation's atomic boundaries (load-state, compute, store-state-FINISH, load-tail, conditional-finalize-call). Separate `MCFinalizeRace` action where two threads race in finalize CAS.
- **Adversary**:
  - `MCStaleRead` on the relaxed `tail.pos` load at `soring.c:483`.
  - `MCStaleHead` on the relaxed head load in stage_move_head at `soring.c:228` — same as Family A pattern.
  - `MCWrongReleaseN` for caller-misuse D.3 (release with `n_actual ≠ n_acquired`).
  - `MCFtokenWrap` to reach the 2^32 wrap (bounded scenario).
- **Granularity**: actions split at every atomic load/store and every CAS site.
- **Invariants**:
  - `∀s: tail[s] ≤ head[s] ≤ tail[s+1]` (stage ordering).
  - `state[s][idx]` is updated only by the thread that holds the corresponding ftoken.
  - No two threads concurrently observe the same `(stage, ftoken)` as START.
  - Eventually-finalised: every FINISH state is eventually consumed by some finalize call (liveness; hold under fair scheduling assumption).

**Priority**: **HIGH** (D.1, D.2, D.3) / **MEDIUM** (D.4). **Rationale**: new code, multiple plausible hazards, no prior verification. The maintainer apparently overlooked SORING when applying the Nov 2025 partial-order fix.

---

### Family E: Peek API atomicity & NDEBUG-masked invariants

**Mechanism**: the peek_start / copy / peek_finish API depends on a documented contract that the caller passes a `n` to `_finish_` no greater than what `_start_` returned. `RTE_ASSERT` is compiled out under `NDEBUG`; on contract violation, `_finish_` silently sets `n=0` and rolls head back to tail, discarding all reserved slots and any data the user already wrote into them. Additionally, `peek_zc_start` on an unsupported sync mode (MT, MT_RTS) returns `n=0` but leaves `zcd->{ptr1,ptr2,n1}` uninitialised — caller may dereference garbage if it doesn't check `n`.

**Evidence**:
- Historical: `708d904451` (2020) "ring: fix tail in peek API for ST mode" — wrong field assigned, identical class of fragile peek bookkeeping.
- Code analysis:
  - `rte_ring_peek_elem_pvt.h:30-45, 74-89` — `RTE_ASSERT(n >= num)` + `num = (n >= num) ? num : 0` masking.
  - `rte_ring_peek_zc.h:138-153, 346-361` — uninitialised `zcd` on unsupported mode.
  - `rte_ring_peek_zc.h:526-530` — `rte_ring_dequeue_zc_finish` calls non-zc variant (asymmetry with `enqueue_zc_finish`).

**Affected code paths**: `rte_ring_enqueue_elem_finish`, `rte_ring_dequeue_elem_finish`, `rte_ring_enqueue_zc_*_start/_finish`, `rte_ring_dequeue_zc_*_start/_finish`, `__rte_ring_st_get_tail`, `__rte_ring_hts_get_tail`, `__rte_ring_st_set_head_tail`, `__rte_ring_hts_set_head_tail`.

**Suggested modeling approach**:
- **Variables**: per-thread `reserved_n` from `_start_`; `committed_n` passed to `_finish_`.
- **Actions**: `MCMisuseFinishN` chooses `committed_n ∈ [0, reserved_n + k]` where `k` represents over-commit due to caller bug.
- **Granularity**: action-level; this is harness-level adversary, similar to Family B.
- **Invariant**: data integrity — every slot returned by `_start_` either reaches `_finish_` with consistent data or is rolled back without partial commits being visible.

**Priority**: **MEDIUM**. **Rationale**: real fragility but most impact is *test-verifiable* (unit tests under `RTE_PEDANTIC` / debug mode). TLA+ adds value mainly for the rollback-vs-other-thread interleaving.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| Item | Why | How |
|---|---|---|
| RTS update_tail with split head/tail loads, where head load may return stale value | Family A — BZ-1527 candidate | New action `RTSUpdateTailLoadHead` separated from `RTSUpdateTailCAS`; expose stale-read via `MCStaleRead` adversary |
| Generic harness for sync_type misuse | Family B | `ClientHarness` chooses ring sync_type and API entry-point non-deterministically; `MCMisuseAPI` action |
| Default-mode new release/acquire chain (no in-loop fence) | Family C | Re-tag prior-round actions with C11 orderings; remove fence; verify equivalent invariants hold |
| SORING `__rte_soring_stage_move_head` with relaxed head load | Family D.1 | Same as Family A pattern, applied to SORING stage move_head |
| SORING `release` FINISH-store + tail.pos load split | Family D.2 | New action `SORingReleaseFinish` distinct from `SORingReleaseTailCheck`; expose lost-finalize via `MCStaleRead` on tail.pos |
| SORING release-count mismatch | Family D.3 | `MCWrongReleaseN` adversary with bounded delta; invariant on ftoken consistency |
| SORING ftoken wraparound | Family D.4 | Bounded `MCFtokenWrap` scenario; invariant: no two acquired ftokens equal |
| Peek finish with mismatched `n` | Family E | `MCMisuseFinishN` adversary; invariant on data-rollback consistency |

### 3.2 Do Not Model (with rationale)

| Item | Why not |
|---|---|
| HTS livelock under producer crash (Family F) | Liveness-only; documented design property of HTS. No safety violation. Better as a documented system invariant ("HTS has no progress under failure"). |
| 32-bit head/tail wraparound for default/HTS modes | The mod-2^32 arithmetic is correct under the documented `in_flight < 2^31` invariant. Bounded model checking would need a 2^32 counter, which is impractical. Document the invariant; rely on prior-round confirmation that wrap is safe. |
| Compiler / LTO false-positive overruns (BZ-1726, BZ-1864) | Compiler bug-class, not a TLA+-tractable runtime bug. Test-verifiable via static analysis runs. |
| Unaligned 64-bit `ht.raw` access on 32-bit ARM (BZ-685) | Hardware ABI / alignment issue; below the abstraction level TLA+ can model. Code-review-only. |
| GCC-12 stringop-overflow warning (BZ-1149) | Compiler diagnostic; already fixed by `dea4c54155`. |
| BZ-987 tailq circular | External corruption; no reproducer; not a ring-internal bug. |
| `rte_ring_dequeue_zc_finish` calling non-zc variant | Pure code-quality / symmetry issue; functionally equivalent. Code-review-only. |
| Pure performance trade-offs in Nov 2025 patch (option (1) seq-cst vs (2) partial-order vs (3) underflow detection) | The maintainer chose option (2) on contract grounds. Not a correctness question; doc-only. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| `MCStaleHeadRTS` | per-thread `local_h` snapshot in update_tail | Models the missing acquire on `head.raw` at rts_elem_pvt.h:49 | A |
| `ClientHarness` | `ring.sync_type`, `api.target_sync_type` | Models caller invoking wrong mode-specific API | B |
| `C11Ordering` annotation set | per-load/per-store ordering label | Tags each atomic op with its actual C11 ordering | A, C, D.1 |
| `SORingState` | `head[s]`, `tail[s]`, `state[s][i]`, `ftoken_epoch` | Models per-stage progress + state ring | D |
| `MCWrongReleaseN` | `delta ∈ {-1, 0, +1}` | Models caller releasing with wrong n | D.3 |
| `MCFtokenWrap` | bounded counter for pos wrap | Models 2^32 ftoken collision | D.4 |
| `MCMisuseFinishN` | `commit_n` chosen from `[0, reserved_n + k]` | Models peek finish over-commit | E |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `RTSPosCntConsistent` | Safety | `(rts.tail.cnt == rts.head.cnt) ⇒ (rts.tail.pos == rts.head.pos)` | Family A |
| `APIContractConsistent` | Safety | API call's expected sync_type == ring.sync_type | Family B |
| `DefaultPartialOrder` | Safety | Standard MPMC element-id consistency under new C11 ordering | Family C |
| `SORingStageOrdered` | Safety | `∀s: tail[s] ≤ head[s] ≤ tail[s+1]` | Family D |
| `SORingNoLostFinalize` | Liveness | Every FINISH-stamped slot is eventually freed (under fair scheduling) | Family D.2 |
| `SORingFtokenUnique` | Safety | At any moment, no two in-flight acquires share `(stage, ftoken)` | Family D.4 |
| `SORingReleaseExact` | Safety | The `n` passed to release == the `n` returned by acquire for the same ftoken | Family D.3 |
| `PeekRollbackAtomic` | Safety | Peek finish either commits exactly `committed_n` slots or rolls back exactly `reserved_n - committed_n` slots, with no partial-commit visible to other threads | Family E |
| `NoStaleConsumeRTS` | Safety | Consumer dequeue never reads from a slot whose producer hasn't published | Family A, C |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| MC-A1 | RTS update_tail relaxed head load admits stale `h.cnt`/`h.pos` after CAS-failure retry | `RTSPosCntConsistent` | A |
| MC-B1 | Direct call to `rte_ring_mp_hts_*` on non-HTS ring | `APIContractConsistent` | B |
| MC-B2 | Direct call to `rte_ring_mp_rts_*` on non-RTS ring | `APIContractConsistent` | B |
| MC-C1 | New default-mode ordering is sufficient without in-loop thread fence | `DefaultPartialOrder` | C |
| MC-D1 | SORING `__rte_soring_stage_move_head` with stale head load | `SORingStageOrdered` | D.1 |
| MC-D2 | SORING release + tail.pos load races; finalize lost | `SORingNoLostFinalize` (liveness) | D.2 |
| MC-D3 | SORING release with wrong n | `SORingReleaseExact` | D.3 |
| MC-D4 | SORING ftoken wraparound | `SORingFtokenUnique` | D.4 |
| MC-E1 | Peek finish with `n > reserved_n`; data wrote to slot is silently dropped | `PeekRollbackAtomic` | E |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | BZ-685 SIGBUS on armhf — likely 64-bit `ht.raw` alignment | Run `ring_autotest` under hugetlbfs-disabled / unaligned allocation forced on armhf CI |
| TV-2 | BZ-1726 SORING LTO overrun — verify call path is truly unreachable | Build with LTO + `-O3` + AddressSanitizer; run soring-stress with various esize values |
| TV-3 | Peek finish with `num > reserved` under NDEBUG | Unit test deliberately calls `_finish_` with over-large `num`; assert no data lost |
| TV-4 | Peek-zc start on MT/MT_RTS ring under NDEBUG | Unit test triggers the unsupported-mode path; assert `zcd` is zeroed and caller observes `n=0` |
| TV-5 | RTS hang on AArch64 RCpc / PowerPC | Build PPC64 and aarch64 stress harness with `htd_max=1`; confirm whether November 2025 patch closes BZ-1527 in real-world execution |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `rte_ring_dequeue_zc_finish` delegates to non-zc variant | Symmetry fix: delegate to `rte_ring_dequeue_zc_elem_finish` |
| CR-2 | HTS livelock under producer crash | Document as design-intent in `rte_ring_hts.h` header doc-comment |
| CR-3 | 32-bit head/tail wraparound | Document `in_flight < 2^31` invariant in `rte_ring_core.h` header |
| CR-4 | `RTE_ASSERT` masking peek API misuse | Replace with `RTE_VERIFY` or return a non-zero error code |
| CR-5 | Mode-specific public APIs lack `sync_type` guard | Add a `RTE_ASSERT(r->prod.sync_type == RTE_RING_SYNC_MT_HTS)` (or analogous) at each entry point |
| CR-6 | SORING `__rte_soring_stage_move_head` not updated to Nov 2025 pattern | Apply the same release/acquire conversion to SORING |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/dpdk-ring_2/.specula-output/analysis-report.md`
- **Key source files**:
  - `lib/ring/rte_ring_c11_pvt.h:74-143` (default-mode move_head)
  - `lib/ring/rte_ring_hts_elem_pvt.h:25-162` (HTS update_tail + move_head)
  - `lib/ring/rte_ring_rts_elem_pvt.h:25-176` (RTS update_tail + move_head — Family A)
  - `lib/ring/rte_ring_peek_elem_pvt.h:30-108` (peek get_tail / set_head_tail — Family E)
  - `lib/ring/soring.c:67-487` (SORING — Family D)
  - `lib/ring/rte_ring_core.h:65-145` (data structures, sync_type enum)
- **Key commits**:
  - `a4ad0eba9d` (default-mode partial-order fix, 2025-11-11)
  - `66d5f96278` (HTS partial-order fix, 2025-11-11)
  - `36b69b5f95` (RTS partial-order fix, 2025-11-11) — see Family A residual
  - `b5458e2cc4` (SORING introduction, 2024-12-06) — see Family D
  - `c8d909aeb7` (HTS/RTS bulk enqueue dispatch fix, 2020) — historical Family-B precedent
  - `85cffb2eccd9` (read tail before slots, 2019) — historical ordering fix subsumed by Nov 2025
- **DPDK Bugzilla**:
  - https://bugs.dpdk.org/show_bug.cgi?id=1527 (open — Family A confirmation target)
  - https://bugs.dpdk.org/show_bug.cgi?id=1726 (open — TV-2)
  - https://bugs.dpdk.org/show_bug.cgi?id=685 (open — TV-1)
- **Reference algorithm**: classical Lamport split-counter MPMC ring; no canonical paper, but the implementation is documented in `doc/guides/prog_guide/ring_lib.rst`. For RTS-style relaxed publication, the closest published reference is the LMAX Disruptor's "barriers" mechanism.
- **Prior round verification**: 4.1B states, MPMC core under sequential-consistency / pre-Nov-2025 ordering, 0 bugs.
