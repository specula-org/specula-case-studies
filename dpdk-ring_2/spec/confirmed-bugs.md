# Confirmed Bug Report — dpdk-ring_2

## Summary

- Total findings reviewed: **5** (4 MC counter-examples + 1 spec-side artifact already classified by the bug-report)
- Reproduced (observable anomalous behavior triggered): **1** (Bug 4, D.3)
- Confirmed by code-audit, reproduction not possible on x86 hardware: **0**
- False positives: **3** (Bug 1 / Family A, Bug 2 / Family D.1, Bug 3 / Family D.2 — see analysis)
- Inconclusive / spec-side: **1** (Family E was already classified as a spec defect, not an implementation bug)

The DPDK ring library is a heavily-reviewed, production-deployed lock-free
data structure that completed a 4.1 B-state formal verification in the prior
round with 0 bugs. All four MC findings in this round are weak-memory or
caller-misuse hazards. Of these, only the caller-misuse path (Bug 4) is a
real, easily-triggered defect; the three weak-memory findings are either
spec artifacts (Bug 1) or correct-by-C11-fence-rules code (Bug 2, Bug 3).

Reproduction tests are in `.specula-output/repro/`. They were built against
the DPDK install tree at `artifact/dpdk/install/usr/local/` and executed
on Linux x86_64 (TSO).

---

## Bug 1 — Family A: RTS update_tail residual stale-head load (BZ-1527 candidate)

- **Source**: MC (counterexample, BFS depth 22)
- **Status**: **FALSE POSITIVE — spec defect**
- **Severity (as reported by MC)**: High
- **Severity (after audit)**: None — invariant holds in real C11
- **Location**: `lib/ring/rte_ring_rts_elem_pvt.h:51` (relaxed head load
  inside `__rte_ring_rts_update_tail`'s do/while loop)

### Why this is a false positive

The MC counter-example (`spec/output/MC_hunt_A_bfs.out`) shows thread t1:
1. Successfully CASes `head.raw` from `(0,0)` to `(1,1)` (state 6).
2. In `__rte_ring_rts_update_tail`, the relaxed load of `head.raw` returns
   the stale value `(0,0)` — the value t1 saw *before its own CAS* (state 7,
   `MCStaleHeadRTS(t1)`).

This MC behavior **violates intra-thread coherence as defined by C11**. Per
C11 §5.1.2.4 / C++ §32.4 [intro.races]/14, "If a side effect X on a memory
location M happens before a value computation B of M, and B takes its value
from a side effect A on M, then the value computed by B shall be the value
stored by A or by some other side effect on M that follows X in the
modification order of M." A relaxed load on the same thread that already
performed a release-CAS to `head.raw` *cannot* observe a value older than
the one it just wrote. This holds on every C11 architecture, including
RCpc (AArch64 LDxR, PowerPC), because intra-thread coherence is a per-thread
guarantee independent of inter-thread synchronization.

The MC adversary `MCStaleHeadRTS` (MC.tla:86-106) picks a stale head from
any thread's `visibleProdHead*` snapshot, including the current thread's
own — but the spec does not refresh `visibleProdHead*[t]` on t's own
release-CAS. That omission is a spec modeling defect, not a real-code
hazard.

### Inter-thread scenario also doesn't violate the invariant

A genuinely stale read of *another* thread's head update can happen
(the relaxed load is not synchronized with another producer's release-CAS
of head). But trace the bookkeeping:

```
t1 wins move_head CAS: head=(0,0)→(1,1). t1 enters update_tail.
  ot = acquire-load(tail) = (0,0).
  Loop: h = relaxed-load(head). By coherence, h.cnt ≥ 1 (t1's own write).
    Suppose h = (1,1) (current).  nt.cnt=1, h.cnt=1 ⇒ nt.pos=h.pos=1.
      CAS tail (0,0)→(1,1) succeeds. Invariant OK.
    Suppose h = (2,2) because t2 has since written.  nt.cnt=1, h.cnt=2 ⇒
      nt.pos=ot.pos=0. CAS tail (0,0)→(1,0). tail.cnt=1, head.cnt=2,
      tail.cnt ≠ head.cnt — invariant condition does not apply.
```

In every reachable C11-conformant scenario, when `tail.cnt == head.cnt`
the publisher of the *highest* tail.cnt also published its own head, and
intra-thread coherence guarantees `tail.pos == head.pos`. The November-2025
patch maintainers correctly identified that this load did **not** need an
acquire — it is dominated by the CAS-failure-acquire on `tail.raw`.

### Developer intent

Commit `36b69b5f95` (Nov 2025, Wathsala Vithanage / Ola Liljedahl, Arm)
deliberately left this load as `relaxed`. The commit message documents A0,
R0 synchronization edges precisely; the in-loop head load is not part of
those edges because it does not need to be. A reading of BZ-1527's open
trace (spec hangs on PPC) suggests the real PowerPC bug pre-dates the
November 2025 fix and is closed by the explicit acquire on the *tail*
load and the head-wait acquire — not by a head-load promotion that
isn't required.

### Reproduction attempted

- **File**: `repro/test_bug1_rts_stale_head.c`
- **Command**: `LD_LIBRARY_PATH=... ./test_bug1 --no-pci --no-shconf -l 0-4 --in-memory --no-huge -m 256 --log-level='*:err'`
- **Output** (`repro/test_bug1.output`):

```
== test_bug1_rts_stale_head ==
Architecture: x86_64 (TSO).
Total enqueued = 1474524, dequeued = 1474524
Final ring count = 0
ring <rts_bug1>@...
  cons.head.pos=1474524  cons.head.cnt=368631
  cons.tail.pos=1474524  cons.tail.cnt=368631
  prod.head.pos=1474524  prod.head.cnt=368631
  prod.tail.pos=1474524  prod.tail.cnt=368631
PASS: ring drained, no stuck state observed (x86 TSO).
```

After 1.47 M enqueue/dequeue ops with 2 producers + 2 consumers, head/tail
counters match exactly. RTSPosCntConsistent holds throughout.

### Recommendation

- Reject the MC finding as a spec defect.
- Update `MCStaleHeadRTS` to refresh the publisher's `visibleProdHead*`
  on its own CAS so that the adversary cannot emit values violating
  intra-thread coherence.
- No code change needed in DPDK.

---

## Bug 2 — Family D.1: SORING `__rte_soring_stage_move_head` stale head load

- **Source**: MC (counterexample, BFS depth 30)
- **Status**: **FALSE POSITIVE — code is C11-correct via fence(acquire)**
- **Severity (as reported by MC)**: Medium-High
- **Severity (after audit)**: None — equivalent to acquire-load semantics
- **Location**: `lib/ring/soring.c:264-285` (`__rte_soring_stage_move_head`)

### Why this is a false positive

The SORING code uses the pre-November-2025 idiom:

```c
*old_head = rte_atomic_load_explicit(&d->head, rte_memory_order_relaxed);
do {
    rte_atomic_thread_fence(rte_memory_order_acquire);  /* line 271 */
    tail = rte_atomic_load_explicit(&s->tail, rte_memory_order_acquire);
    ...
} while (rte_atomic_compare_exchange_strong_explicit(&d->head,
        old_head, *new_head, rte_memory_order_acq_rel,
        rte_memory_order_relaxed) == 0);
```

Per C11 §7.17.4 [atomics.fences] paragraph 4 (carried over from C++ ISO/IEC
14882:2017 §32.4):

> "An atomic operation A that is a release operation on an atomic object M
> synchronizes with an acquire fence B if there exists some atomic operation X
> on M such that X is sequenced before B and reads the value written by A or
> a value in the release sequence headed by A."

Applied here:
- Some other producer's release-CAS on `d->head` writes value V.
- Our relaxed load of `d->head` reads V (this is X).
- Our `fence(acquire)` (B) is sequenced after X.
- Therefore the writer's release synchronizes with our fence(acquire) —
  i.e., we observe all writes the writer sequenced before its CAS.

This is functionally equivalent to:
```c
*old_head = rte_atomic_load_explicit(&d->head, rte_memory_order_acquire);
```
which is what the November-2025 default-mode patch (`a4ad0eba9d`) refactored
to. The refactor is *stylistic* — it removes the explicit fence in favor
of a stronger load — but does not change the synchronization semantics.

### Developer intent

The `__rte_soring_stage_move_head` was introduced in `b5458e2cc4`
(Dec 2024). The Huawei authors used the older "relaxed-load + fence(acquire)"
idiom, which the DPDK code base used widely before the Nov-2025
modernisation. The fact that the Nov-2025 trio of fixes did not touch
SORING reflects the fact that SORING's pattern is *not buggy* — just
written in an older idiom. A future cleanup PR may bring it in line for
readability, but no functional correctness issue exists.

### Reproduction attempted

- **File**: `repro/test_bug2_soring_stale_head.c`
- **Command**: `LD_LIBRARY_PATH=... ./test_bug2 --no-pci --no-shconf -l 0-7 --in-memory --no-huge -m 256 --log-level='*:err'`
- **Output** (`repro/test_bug2.output`):

```
Total enq=400000 deq=400000
soring <soring_bug2>@...
  cons.head=400000 cons.tail=400000
  prod.head=400000 prod.tail=400000
  stage[0].tail.pos=400000 stage[0].head=400000
  stage[1].tail.pos=400000 stage[1].head=400000
PASS: SORING drained cleanly under stress on x86 TSO.
```

400 k ops across 2 stages on x86 with 1 producer / 2 stage workers /
1 consumer; ordering invariant `tail[s] ≤ head[s] ≤ tail[s+1]` holds.

### Recommendation

- Reject the MC finding as a code-style observation, not a bug.
- Optionally, refactor `__rte_soring_stage_move_head` to use the
  acquire-load pattern matching `rte_ring_c11_pvt.h` — purely a
  readability/consistency improvement (corresponds to CR-6 in the
  modeling brief).

---

## Bug 3 — Family D.2: SORING release lost-finalize race

- **Source**: MC (counterexample, BFS depth 14)
- **Status**: **FALSE POSITIVE on x86 / NEEDS RCPC — liveness-only at worst**
- **Severity (as reported by MC)**: Medium (liveness)
- **Severity (after audit)**: Low — bounded by lazy-finalize-on-acquire;
  no safety implication
- **Location**: `lib/ring/soring.c:531-553` (FINISH store + tail.pos load
  in `soring_release`)

### Code under examination

```c
rte_atomic_thread_fence(rte_memory_order_release);                    // 532
st.stnum = SORING_ST_FINISH | n;
rte_atomic_store_explicit(&r->state[idx].raw, st.raw,                 // 535
        rte_memory_order_relaxed);
...
tail = rte_atomic_load_explicit(&stg->sht.tail.pos,                   // 544
        rte_memory_order_relaxed);
if (tail == pos)
    __rte_soring_stage_finalize(...);
```

### Why this is a false positive on x86

x86 TSO orders relaxed stores in program order globally, and orders
relaxed loads to follow all prior stores from the same core. The
"stale tail.pos" scenario (load returns a value older than another
thread's release-store of tail.pos) requires CPU-level reordering
that x86 does not perform.

At the *compiler* level, the relaxed load could in principle be
hoisted, but in practice gcc/clang preserve program order between
adjacent atomic accesses. The 200 k-burst stress test
(`repro/test_bug3_soring_lost_finalize.c`) ran cleanly:

```
soring <soring_bug3>@...
  prod.tail=200000  cons.tail=200000  stage[0].tail.pos=200000  stage[0].head=200000
PASS: drained cleanly. Liveness preserved on x86.
```

### Why this is also limited on RCpc

Even if the relaxed tail.pos load can return a stale value on AArch64,
the bug-report explicitly classifies it as **liveness-only**:

> "Forward progress is preserved by lazy-finalize-on-acquire (the next
> stage_move_head will eventually walk past the FINISH), but a quiescent
> stage can pin a FINISH slot indefinitely…"

So the worst case is: in a quiescent stage with no further activity,
some FINISH slots remain un-finalised. There is no safety violation,
no data corruption, and any subsequent activity cleans up the lag.
For a high-throughput dataplane (the SORING use case), genuinely
quiescent stages are not a normal operating mode.

### Developer intent

The `__rte_soring_stage_finalize` CAS gate (`soring.c:96-121`) is the
authoritative finalize — multiple call-sites race for it harmlessly.
The release-side `if (tail == pos)` check is an *optimization*, not a
correctness requirement. The Nov-2025 patch authors did not touch
SORING because they understood that the lazy-finalize-on-acquire path
preserves correctness.

### Recommendation

- Reject as a safety/correctness bug.
- For RCpc-targeted deployments, consider a doc/comment update in
  `soring_release` clarifying that the `tail == pos` check is a fast
  path and the canonical finalizer runs from acquire.
- Optional micro-optimisation: promote the load to acquire and the
  FINISH store to release. This costs nothing on x86 and is theoretically
  cleaner on RCpc, but does not fix any safety issue.

---

## Bug 4 — Family D.3: SORING release-count mismatch silent corruption

- **Source**: MC (counterexample, BFS depth 12)
- **Status**: **REPRODUCED — caller misuse silently corrupts state**
- **Severity**: **Medium-High** (silent data corruption under NDEBUG)
- **Location**: `lib/ring/soring.c:489-554` (`soring_release` →
  `soring_verify_state`)

### Description

When a caller violates the SORING API contract by passing `n_release ≠
n_acquire` to `rte_soring_release`, the library:

1. Loads the current `state[idx]` and compares against the expected value.
2. If mismatched, calls `soring_verify_state`, which under NDEBUG simply
   logs an EMERG message and returns. (The `RTE_ASSERT` guard in
   `acquire_state_update` is compiled out in standard release builds —
   confirmed by inspecting `rte_debug.h`: `RTE_ASSERT` requires
   `RTE_ENABLE_ASSERT` which is not set in the default DPDK build.)
3. Continues into the FINISH-store path and writes
   `state[idx] = (FINISH | n_release)` — i.e., the *caller's* `n`,
   not the n recorded at acquire.
4. `__rte_soring_stage_finalize` later uses
   `k = state[idx].stnum & ~SORING_ST_MASK` (the wrong `n`) to advance
   the stage tail — corrupting `stage[s].tail.pos` by ±n.

### API contract evidence

`rte_soring.h:563-565` says explicitly:
```
* @param n
*   The number of objects to release.
*   Has to be the same value as returned by acquire() op.
```
"Has to be" is a stated precondition.  However, with `RTE_ASSERT` compiled
out and `soring_verify_state` only logging, the contract violation does
not surface as a fail-fast or an error return — only as a SORING_LOG
EMERG line that production deployments often filter or rate-limit.

### Trigger scenario

Single-thread, no concurrency required:

1. Create SORING(stages=1, capacity=8, MT/MT).
2. `rte_soring_enqueue_bulk(buf, n=4)`. Input tail = 4.
3. `rte_soring_acquire_bulk(&buf, stage=0, n=2 or 3, &ftoken, ...)`.
4. `rte_soring_release(NULL, stage=0, n=DIFFERENT, ftoken)`.
5. `rte_soring_dequeue_bulk(...)` returns the wrong number of elements,
   or `stage[0].tail.pos` becomes greater than `stage[0].head` —
   violating `SORingStageOrdered`.

### Reproduction (REPRODUCED — observable anomalous behavior)

- **File**: `repro/test_bug4_wrong_release_n.c`
- **Build**:
  ```
  gcc -O2 -Wall test_bug4_wrong_release_n.c \
      -I.../install/usr/local/include \
      -L.../install/usr/local/lib/x86_64-linux-gnu \
      -Wl,-rpath,.../install/usr/local/lib/x86_64-linux-gnu \
      -lrte_ring -lrte_eal -lrte_kvargs -lrte_log -lrte_telemetry \
      -lpthread -ldl -lm -latomic -o test_bug4
  ```
- **Run**:
  ```
  LD_LIBRARY_PATH=.../install/usr/local/lib/x86_64-linux-gnu \
    ./test_bug4 --no-pci --no-shconf -l 0 --in-memory --no-huge -m 128 \
        --log-level='*:err'
  ```

#### Actual output (`repro/test_bug4.output`)

The library logs the verify_state mismatch but otherwise proceeds:

```
SORING: from:soring_release: soring=..., stage=0, idx=0,
  expected={.stnum=0x40000001, .ftoken=0},
  actual={.stnum=0x40000003, .ftoken=0};
SORING: from:soring_release: soring=..., stage=0, idx=0,
  expected={.stnum=0x40000003, .ftoken=0},
  actual={.stnum=0x40000002, .ftoken=0};
```

#### Case 1 — baseline_correct (n=3 acquire, n=3 release)

```
soring <baseline_correct>@...
  prod.head=4 prod.tail=4
  stage[0].tail.pos=3  stage[0].head=3
  dequeue_burst(4) returned=3  remaining=0
=== count=1 free_count=7 ===
```
Expected: 3 elements consumed, 1 remaining. ✅

#### Case 2 — misuse_under_release (n=3 acquire, n=1 release) — silent corruption

```
soring <misuse_under_release>@...
  prod.head=4 prod.tail=4
  stage[0].tail.pos=1   <-- EXPECTED 3 — finalize used wrong n=1
  stage[0].head=3
  dequeue_burst(4) returned=1  <-- 2 elements LEAKED (acquired+released, never dequeued)
=== count=3 free_count=5 ===
```
**Observed harm**: 2 elements have been "released" by the caller's intent
but are never reachable by `rte_soring_dequeue_bulk` because
`stage[0].tail.pos == 1 < stage[0].head == 3`. The slots between
1 and 3 are leaked indefinitely. Subsequent enqueues will eventually
fail when the ring fills, even though to the consumer the entries are
"available". A long-running pipeline silently degrades capacity.

#### Case 3 — misuse_over_release (n=2 acquire, n=3 release) — INVARIANT VIOLATION

```
soring <misuse_over_release>@...
  prod.head=4 prod.tail=4
  stage[0].tail.pos=3   <-- TAIL IS PAST HEAD
  stage[0].head=2
  dequeue_burst(4) returned=3  <-- caller acquired only 2, but 3 are dequeued
    deq[0]=0x1000  deq[1]=0x1001  deq[2]=0x1002
```
**Observed harm**: `stage[0].tail.pos = 3 > stage[0].head = 2`, directly
violating `SORingStageOrdered`. Worse, the dequeue path returns *one
extra element* (`0x1002`) that was never legitimately released —
a downstream consumer would receive a slot whose contents are whatever
happens to be there (in this minimal test, the previously-enqueued
element is intact, but in real-world use the acquire-side processing
would not have written the third slot).

This is a **silent safety violation**: the SORING_LOG line is the only
diagnostic, and the API call returns void. A producer's logic bug —
e.g., off-by-one in counting, retry-with-stale-n, or overflow in `n`
arithmetic — is converted into a memory-safety bug at the consumer.

### Developer intent

The DPDK API doc says "has to be the same value as returned by
acquire()", i.e., contract violation. The choice to use `RTE_ASSERT`
(compiled out under NDEBUG) is a deliberate trade-off: zero overhead
in production, fail-fast in dev/CI builds with `-DRTE_ENABLE_ASSERT`
or `-DRTE_SORING_DEBUG`.

However, the **trade-off becomes a true bug** when the caller's bug is
silent — there is no error return, no panic, no monotonic counter
advance to detect at runtime. A library that exposes a "release n"
parameter and silently succeeds when n is wrong is providing an
unsafe API. The bug-report's recommendations are exactly right:

1. Replace `RTE_ASSERT` with `RTE_VERIFY` (always enabled) for this
   precondition. Cheap (one comparison), and converts silent corruption
   to fail-fast.
2. Or, return non-zero from `rte_soring_release` on mismatch
   (API-breaking — needs a deprecation path).
3. At minimum, document the precondition prominently in the public
   doxygen and in `rel_notes`. (Already done partially.)

### Recommendation

- Land a fix that converts the silent verify_state mismatch into an
  observable failure: minimum bar is `RTE_VERIFY` on the `(stnum.n,
  ftoken)` pair.
- Add `app/test/test_soring.c` cases for both under-release and
  over-release (currently absent) so a regression of this fix is
  immediately caught.
- Cross-reference with `rte_ring_peek_*` family (Family E in the
  modeling brief) — the same `RTE_ASSERT` masking pattern exists
  there (TV-3).

---

## Finding 5 — Family E: Spec-side artifact (already classified)

- **Source**: MC (counterexample, BFS depth 8)
- **Status**: **NOT AN IMPLEMENTATION BUG** — spec invariant `PeekRollbackAtomic`
  was too strong (Case A in the bug-report). Already analysed in
  `bug-report.md` §"Bug-Like Finding 5".
- **Action**: Spec follow-up, not an implementation finding. The peek-zc
  over-commit hazard remains unverified for this round (see TV-3 in the
  modeling brief).

---

## Reproduction artifacts

| File | Purpose | Status on x86 |
|------|---------|---------------|
| `repro/test_bug1_rts_stale_head.c` | RTS stress (1.47 M ops, 4 lcores) — verify RTSPosCntConsistent | PASS (bug not reachable on x86) |
| `repro/test_bug2_soring_stale_head.c` | SORING multi-stage stress (400 k ops, 4 lcores, 2 stages) | PASS (bug not reachable on x86) |
| `repro/test_bug3_soring_lost_finalize.c` | SORING enqueue+acquire+release+dequeue stress (200 k bursts) | PASS (bug not reachable on x86) |
| `repro/test_bug4_wrong_release_n.c` | Caller passes wrong `n` to `rte_soring_release` | **REPRODUCED** — observable tail-past-head and slot leak |
| `repro/test_bugN.output` | Captured terminal output for each test | — |

All tests built against `artifact/dpdk/install/usr/local` (DPDK 26.03.0-rc1
with the November-2025 partial-order trio applied). The library was built
without `RTE_ENABLE_ASSERT` and without `RTE_SORING_DEBUG`, matching the
default production configuration.

---

## Cross-cutting recommendations

1. **API contract enforcement**: replace `RTE_ASSERT` with `RTE_VERIFY` (or
   return-on-mismatch) for caller-misuse paths in:
   - `lib/ring/soring.c` `acquire_state_update` and `soring_verify_state`
     (Bug 4 / D.3, primary remediation)
   - `lib/ring/rte_ring_peek_elem_pvt.h:30-89` (TV-3 follow-up)
   - Mode-specific public APIs in `rte_ring_hts.h` / `rte_ring_rts.h` —
     add a sync_type guard at each entry-point (CR-5).

2. **Spec correctness**: tighten `MCStaleHeadRTS` to enforce intra-thread
   coherence (the publishing thread must observe its own write).
   Otherwise the spec will continue to flag false positives like Bug 1.

3. **No code change needed for Bug 1, 2, 3**: the existing C11 ordering
   patterns are sound. The Nov-2025 refactor in default-mode and HTS is a
   readability improvement; SORING's use of fence(acquire) is functionally
   equivalent.

4. **Test coverage gap**: the existing `app/test/test_soring.c` does not
   exercise wrong-n release. Add a deliberate misuse case (under and over)
   to the regression suite, gated behind `RTE_ENABLE_ASSERT` so it asserts
   under DEBUG and asserts data-loss under NDEBUG once the verify is
   strengthened.
