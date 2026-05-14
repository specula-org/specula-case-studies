# Analysis Report: crossbeam-deque

Audit trail for the four-phase code analysis. The Modeling Brief at `.specula-output/modeling-brief.md` is the primary deliverable; this report is the evidence backing every claim there.

## Phase 1: Reconnaissance

### Repository / artifact

- Path: `/home/ubuntu/Specula/case-studies/crossbeam-deque_2/artifact/crossbeam` (symlinked from sibling `crossbeam-deque` artifact).
- Git head: `03919fed` ("select_macro: Handle block as { $($:tt)* }" on the `master` branch of `crossbeam-rs/crossbeam`).
- Confirmed includes: `23b68fb3` (Feb 2026 fence-Release-Relaxed split) — present.
- Confirmed *does not* include: `1015b21d` (Feb 2026 strong-CAS for Injector::steal*) — `git merge-base 03919fed 1015b21d = 903c2d41` (common ancestor only).

### Code structure

| Path | LOC | Role |
|------|-----|------|
| `crossbeam-deque/src/deque.rs` | 2,233 | Worker + Stealer + Injector + Steal enum |
| `crossbeam-deque/src/lib.rs` | 109 | Module-level docs + re-exports |
| `crossbeam-deque/src/alloc_helper.rs` | 85 (symlink) | `Global::allocate_zeroed` helper |
| `crossbeam-deque/tests/fifo.rs` | 341 | FIFO worker stress tests |
| `crossbeam-deque/tests/lifo.rs` | 343 | LIFO worker stress tests |
| `crossbeam-deque/tests/injector.rs` | 386 | Injector stress tests |
| `crossbeam-deque/tests/steal.rs` | 224 | Stealer-specific tests |

### Atomics inventory

`grep -n "compare_exchange" deque.rs`:

| Site | Op | Variable | Success / Failure ord | Notes |
|------|----|----------|---|---|
| 518 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Worker LIFO len==0 last-task |
| 674 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Stealer `steal` |
| 820 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Stealer `steal_batch` Fifo |
| 867 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Stealer `steal_batch` Lifo loop |
| 1065 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Stealer `steal_batch_and_pop` Fifo |
| 1086 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Stealer `steal_batch_and_pop` Lifo first CAS |
| 1125 | `compare_exchange` (strong) | `front` | `SeqCst`, `Relaxed` | Stealer `steal_batch_and_pop` Lifo loop |
| 1415 | `compare_exchange_weak` | `tail.index` | `SeqCst`, `Acquire` | Injector push |
| 1506 | `compare_exchange_weak` | `head.index` | `SeqCst`, `Acquire` | Injector `steal` |
| 1658 | `compare_exchange_weak` | `head.index` | `SeqCst`, `Acquire` | Injector `steal_batch_with_limit` |
| 1861 | `compare_exchange_weak` | `head.index` | `SeqCst`, `Acquire` | Injector `steal_batch_with_limit_and_pop` |

Other atomics: `front: AtomicIsize`, `back: AtomicIsize`, `buffer: CachePadded<Atomic<Buffer<T>>>` (epoch-managed) for Worker; `head/tail: Position { index: AtomicUsize, block: AtomicPtr<Block> }` for Injector; `state: AtomicUsize` per slot in Injector blocks; `next: AtomicPtr<Block>` per block.

### Concurrency model

- **Worker**: `_marker: PhantomData<*mut ()>` makes it `!Send + !Sync` (deque.rs:208). Single owner. Calls `push`, `pop`, `is_empty`, `len`, `reserve`, `stealer()`. Worker invokes `resize` via `push` overflow and `pop` shrink (FIFO and LIFO).
- **Stealer**: `<T: Send>: Send + Sync + Clone`. Multiple instances may exist (cloned via `Arc` of Inner). Each calls `steal`, `steal_batch*`, `is_empty`, `len`. No mutation of `buffer`; only mutates `front` via SeqCst CAS.
- **Injector**: `<T: Send>: Send + Sync`. Full MPMC. Pushers and stealers race on `tail.index` (push) and `head.index` (steal) via SeqCst CASes. Slot lifecycle managed by `WRITE`/`READ`/`DESTROY` bits on per-slot `state: AtomicUsize`.

### Reference paper alignment

- Chase-Lev 2005 (SPAA): basic dynamic circular deque. Worker push/pop on `back`; stealer steals from `front`. Buffer doubles when full; halves when ≤ ¼ full.
- Le-Pop-Cohen-Nardelli 2013 (PPoPP): correct memory-ordering proof for weak memory models; the `fence(SeqCst)` in LIFO pop and the conditional fence in steal trace directly to this paper's protocol.
- Norris-Demsky 2013 (OOPSLA): CDSchecker model-checked the deque; the implementation uses their flagged orderings.
- crossbeam additions beyond paper:
  - epoch-managed buffer pointer for safe retirement
  - `MaybeUninit<T>`-based `Buffer::read`/`write` (volatile, racy by design at LLVM but UB-free)
  - `cfg(crossbeam_sanitize_thread)` switch for fence-vs-Release-store
  - LIFO and FIFO worker flavors plus inter-flavor batch steal (with reversal pass)

## Phase 2: Bug Archaeology

### Coverage statistics

- **Total commits touching `crossbeam-deque/`**: 178 (`git log --oneline --all -- crossbeam-deque/ | wc -l`).
- **Bug-fix commits identified by keyword search** (`fix|bug|race|panic|deadlock|safe|correct|UB|unsound|stack`): 36 in core deque files; ~12 unique substantive correctness fixes after deduplicating clippy/format/cleanup commits.
- **GitHub issues collected** with `crossbeam-deque` label or "deque" keyword: 50+ found, **10 deeply read** via `gh issue view --comments` (Issues #589, #609, #646, #688, #730, #846, #869, #957, #1116, #1148).
- **GitHub PRs collected**: ~30; **11 deeply read** via `gh pr view --comments` (PRs #726, #728, #779, #829, #849, #855, #871, #903, #1159, #1216, #1233).
- **False-positive exclusions**: 6 tracking/feature/docs issues (#688, #730, #846, #1116, #1148 wrt deque code paths) and 2 upstream-rustc/LLVM issues (#609 ARM hang, #1148 32-bit cast).

### Substantive historical bug fixes (chronological)

| Commit | PR | Date | Component | Severity | Mechanism | Status |
|--------|----|------|-----------|----------|-----------|--------|
| `4d574d40` | — | 2019-01-14 | steal_batch FIFO↔LIFO | High | Reversal step missing for cross-flavor steal; data placed in wrong order. | Fixed |
| `89828aac` | — | 2019-01-15 | steal_batch reversal | High | Reversal mutated `buffer.deref()` (source) instead of `dest_buffer` — corrupted source. Also added `CachePadded` around `Inner::buffer` to fix false sharing with `front`/`back`. | Fixed |
| `68e8708c` | — | 2020-01-02 | Buffer | High | `ManuallyDrop<T>` made the steal-CAS-fail discard path unsound; converted to `MaybeUninit<T>`. (First step toward the eventual #855 fix.) | Fixed |
| `38c07fcf` | #726 | 2021-06-11 | Stealer steal CAS | **Critical (CVE-2021-32810)** | Buffer-resize between `read(f)` and CAS allowed double-take or use-after-free. Fix: re-check `inner.buffer.load() != buffer` before each `front.compare_exchange`. | Fixed |
| `180b462b` | #728 | 2021-07-31 | Same fix backported | Critical | v0.7 backport. | Fixed |
| `8d7db8c0` | #855-related | 2022-06-26 | Buffer.read/write | High | Even after #726, `read_volatile::<T>()` of a slot whose memory was the wrong generation produced an invalid `T` (e.g., dangling `Box<U>`) at the language level — UB regardless of whether the value was used. Switched `read`/`write` to `MaybeUninit<T>`. | Fixed |
| `5a15fc28` | — | 2024-01-06 | Buffer alloc | Low | More-correct buffer allocation (alignment edge-case in epoch's collector); not a deque bug per se. | Fixed |
| `761d0b67` | #1159 | 2024-12-15 | Block::new (Injector) | Medium | (a) `Box::new(Block::default())` allocated 31-slot block on the *stack* before moving into Box, causing stack overflow for large `T`. (b) `alloc_zeroed` may return null; previously not checked. Ported from `crossbeam-channel::list::Block` (#1146/#1147). | Fixed |
| `23b68fb3` | #1233 | 2026-02-21 | Worker push / batch-steal stores | Cleanup | TSan does not understand fences. Pre-fix: `back.store(Release)` plus a redundant `fence(Release)`. Post-fix: under TSan keep `Release` and skip the fence; otherwise emit fence and use `Relaxed` store. Pure perf/ergonomics, no correctness change. | Fixed |
| `1015b21d` | — | 2026-02-21 | Injector steal* | Test-determinism | Switched `compare_exchange_weak` → strong on `head.index` in three Injector steal sites because doctests assumed weak CAS would not fail. **Not in artifact HEAD `03919fed`.** | Fixed (post-HEAD) |

### Open / unresolved issues

| Issue | Title | State | Take |
|-------|-------|-------|------|
| #869 | MacOS M1 Rayon segfault | OPEN | Mitigated by reverting #552 (which had reduced epoch's `MAX_OBJECTS`). taiki-e (maintainer): "I guess the underlying problem is a deque bug." Underlying race not root-fixed. |
| #589 / #646 | TSan data race on volatile reads | CLOSED (false positive / by-design) | Volatile read in `Buffer::read` is racy at LLVM level; safe under `MaybeUninit` no-Drop. Suppress with `race:crossbeam_deque*push` etc. |
| #846 / #730 / #688 / #812 | Loom support / fuzzing / docs | OPEN (tracking) | No bugs; feature/infra. |
| #609 / #1148 / #1116 | Upstream LLVM/rustc / wasi target | CLOSED | Not deque bugs. |

### Issue/PR full discussion summaries

(Compiled from parallel subagent runs of `gh issue view --comments` / `gh pr view --comments`.)

**PR #726** (CVE-2021-32810 fix): Maintainer kmaork reported the race; fix added the `buffer.load() != buffer` guard before each Stealer front-CAS. Approved by taiki-e with no residual concerns.

**PR #855** (MaybeUninit migration): Ralf Jung found that `read_volatile::<Box<T>>` of an old-generation slot was UB at type-validity level even if the value was forgotten. Fix changed `Buffer::read`/`write` signatures from `T` to `MaybeUninit<T>`. Note in PR #855: "I think I fixed a soundness bug. :D" — confirms the post-CVE residual.

**PR #1159** (Block alloc): Ported channel/list fixes #1146 (stack overflow on Box::new of 31-slot block) and #1147 (null-check on `alloc_zeroed`) into Injector and SegQueue. Added stack-overflow regression test with `T = [u8; 32_768]`.

**PR #1233** (TSan-aware fence): Discussed in CHANGELOG; pure ergonomics. The fence/store split is now controlled by a build-script-emitted cfg.

**Issue #869** (MacOS M1 Rayon segfault): Reporter HackerFoo, with crossreferenced rayon-rs/rayon#956. Fix workaround: revert PR #552 in PR #879 (which had reduced epoch's `MAX_OBJECTS` from 128 to 64, making the deque race more likely to trigger). The underlying race remains theoretical — no minimal repro at the deque level.

**Issue #589** (TSan): Reporter cuviper. Discussion concluded the race is fundamental to Chase-Lev's design (volatile read-of-stale-value is by-design; the value is forgotten on CAS-fail). Gankra: "still a problem, but it's fundamental to the design."

## Phase 3: Deep Analysis

Three parallel subagents read the file in three sections (lines 1-552 Worker; lines 553-1180 Stealer; lines 1180-2065 Injector). The complete subagent transcripts are reproduced as evidence below; here are the cross-referenced findings.

### Verified findings: BY-DESIGN (no further action)

| ID | Site | Mechanism | Evidence |
|----|------|-----------|----------|
| BD-1 | deque.rs:418-432 | `fence(Release)` + `back.store(Relaxed)` paired with stealer `back.load(Acquire)` | Le et al. 2013 §3 construction; comment at line 422 explicitly cites TSan workaround. |
| BD-2 | deque.rs:489-528 | Worker LIFO pop Dekker pattern (`back.store` → `fence(SeqCst)` → `front.load` → conditional CAS) | Cited in deque.rs:101-113 as Le et al. 2013 protocol. |
| BD-3 | deque.rs:515-528 | Strong (not weak) CAS on len==0 last-task path | Spurious failure would discard a real popped task via `task.take()`; correctly chosen. |
| BD-4 | deque.rs:289-322 | `Worker::resize` swap + `defer_unchecked` retire | Stealer's epoch pin keeps old buffer alive until reader drains. |
| BD-5 | deque.rs:670, 816, 863, 1061, 1121 | `inner.buffer.load(Acquire) != buffer` re-check before front-CAS | Closes CVE-2021-32810. Read-then-recheck pattern is sound because `buffer` lives under `guard` and `MaybeUninit::forget` of unread value is no-Drop. |
| BD-6 | deque.rs:78-90 | Volatile read/write on `MaybeUninit<T>` instead of `T` | Closes #589, #855. |
| BD-7 | deque.rs:208 | Worker `!Send + !Sync` via `PhantomData<*mut ()>` | Type system enforces single-worker contract. |
| BD-8 | deque.rs:1284-1301 | Block::destroy walker descends and stops at first READ=0 slot | Mid-batch `break` is harmless because foreign walkers can only have anchor `count ≥ new_offset`, descend to slot `new_offset-1`, set DESTROY there, return — never touching `[offset..new_offset-1)`. The ascending loop visits `new_offset-1` last, so `break` fires only after all earlier slots are READ-marked. |
| BD-9 | deque.rs:1415, 1394-1444 | `compare_exchange_weak` retry loop in Injector::push | Pre-allocated `next_block` is preserved across spurious retries (deque.rs:1407-1410); no double-allocation. |
| BD-10 | deque.rs:1428-1429 | `tail.block` Release before `block.next` Release | No reader path observes new `tail.block` then dereferences old `block.next`; `wait_next` Acquire-spins independently. |
| BD-11 | deque.rs:1988-2021 | `Injector::len` double-load idiom | SeqCst tail-load × 2 sandwiches a head-load; if tail unchanged, indices are consistent. |
| BD-12 | deque.rs:660 / 750 | Empty test in stealer paths | False-Empty (push happens after our load) is benign linearization to "empty at load time"; converse is impossible because Acquire-loads can't see future. |
| BD-13 | deque.rs:895-907, 1148-1160 | FIFO→LIFO reversal pass on `dest_buffer` post-CAS pre-back-store | Other stealers cannot steal from `dest` because `dest.back` reflects pre-batch value; safe. |

### Verified findings: SUSPECTED (model-checkable / model-relevant)

| ID | Site | Mechanism | Why suspect |
|----|------|-----------|-------------|
| SU-1 | deque.rs:1083-1087 | `Stealer::steal_batch_with_limit_and_pop` Lifo first CAS — **only** front-CAS site without a `buffer.load() != buffer` re-check | Asymmetric vs all 5 peers (deque.rs:670, 816, 863, 1061, 1121). Currently safe under "resize preserves indices" invariant (deque.rs:299-303 copies live slots verbatim into the new buffer at the *same* indices). But the safety derives from a structural property of `Worker::resize`, not from local control flow; a refactor that compacted resize would silently break this site. Worth a TLA model that varies the resize semantics. |
| SU-2 | deque.rs:299-303 | `Worker::resize` is index-preserving | Implicit invariant relied on by SU-1 and by the read-then-recheck pattern in general. Not commented. |
| SU-3 | deque.rs:467-471 | `Worker::pop` FIFO `fetch_add(SeqCst)` overshoot path with `front.store(f, Relaxed)` restore | Walk-through: if local `b` is fresh (worker is sole writer) and `front >= b` after fetch_add, restore is to the SeqCst-loaded value (not stale). Concurrent stealer that observed our incremented front sees `b - (f+1) < 0` (our `b` = actual back, since worker is sole writer) and returns Empty — they never CAS in this window. **By-design but fragile**; deserves explicit modeling to confirm. |
| SU-4 | deque.rs:651, 765, 1007 | Conditional `fence(SeqCst)` based on `epoch::is_pinned()` | Relies on `epoch::pin()` issuing a SeqCst-equivalent fence on first pin. If a future epoch refactor weakens that, the LIFO last-task race silently breaks. Codify as a contract. |
| SU-5 | deque.rs:1726-1738, 1935-1947 | Block::destroy mid-batch loop with early `break` | Safe under the walker invariant (BD-8) but the invariant is non-obvious. Worth a state-machine TLA model to pin the property. |
| SU-6 | deque.rs:1506, 1658, 1861 | Injector `head.index` `compare_exchange_weak` — artifact HEAD predates the strong-CAS fix `1015b21d` | Spurious failure → `Steal::Retry`. Liveness concern only, not safety. The doctest issue that motivated `1015b21d` is sequential; the protocol-level retry handling is correct. |
| SU-7 | Issue #869 | MacOS M1 Rayon segfault, root-cause not fixed | Maintainer suspects deque race exposed by aggressive epoch GC. Worth folding into Family A as a candidate scenario. |

### Verified findings: SAFE (false alarms; explicit exclusions)

| ID | Initial suspicion | Why excluded |
|----|------------------|---------------|
| FP-1 | TSan reports of data race in `Buffer::read` | By design under `MaybeUninit` no-Drop; documented in #589 and commit `8d7db8c0`. Suppress at the TSan level. |
| FP-2 | `Worker::push` Acquire-load of front (deque.rs:402) could over-/under-estimate len | Only over-estimates (front loads can't see future); over-estimate causes spurious resize, never overwrite. |
| FP-3 | Stealer holding old buffer pointer through resize | Epoch pin keeps old buffer alive; old slot data is identical to new slot data because resize is index-preserving (SU-2). |
| FP-4 | `wait_write`/`wait_next` infinite spin (deque.rs:1224-1281) | Algorithm precondition: pushers must not panic mid-operation. Out of safety scope. |
| FP-5 | Block-pointer ABA after free + reuse by global allocator | Index counter is monotone (~146 years to wrap on 64-bit); CAS prevents acting on stale pointer even at same address. |

### File:line index of all flagged lines

All cited line numbers refer to `crossbeam-deque/src/deque.rs` at git head `03919fed`.

- Worker push: 399-433
- Worker pop FIFO: 466-487
- Worker pop LIFO: 489-545
- Worker resize: 289-322
- Worker reserve: 326-350
- is_empty / len: 363-386
- Stealer steal: 641-683
- Stealer steal_batch (Fifo and Lifo): 746-925
- Stealer steal_batch_and_pop (Fifo and Lifo): 989-1178
- Buffer read/write/at: 64-90
- Inner / Drop: 114-145
- Injector push: 1388-1446
- Injector steal: 1464-1540
- Injector steal_batch: 1564-1743
- Injector steal_batch_and_pop: 1766-1952
- Injector len / is_empty / Drop: 1967-2056
- Block / Slot / wait_*: 1213-1302
- Steal enum + helpers: 2065-2233

## Phase 4: Synthesis

See `modeling-brief.md` for the structured handoff to Spec Generation.

### Bug-family selection rationale

Six families were identified, ranked by combined score (historical bug count × severity × TLA suitability × unfixed-known-bugs).

1. **Family A — Buffer-Resize / Generation Race** — *High*. CVE-level history (#726). Asymmetric site at deque.rs:1083 (SU-1). #869 likely member. Best TLA fit.
2. **Family B — Memory Ordering Bridges** — *High*. Le et al. 2013 protocol surface; multiple ordering-related fixes (#1233, conditional fence at deque.rs:651). No prior fault injection.
3. **Family C — Adversarial Caller Harness** — *Medium*. Documented contract is well-defined (Worker !Sync, Stealer Send+Sync+Clone). Multi-stealer harness was not exercised in prior verification.
4. **Family D — CAS-weak Spurious Failure** — *Medium-Low*. Liveness only; Worker/Stealer side already strong; Injector still weak in artifact HEAD.
5. **Family E — Block Lifecycle Invariant (Injector)** — *Medium*. Non-obvious walker invariant (BD-8); single state-machine TLA model would pin it.
6. **Family F — Empty/Non-Empty Race in Steal-Batch** — *Medium*. Two prior bugs in this exact loop (`4d574d40`, `89828aac`); complex; no prior adversary.

Skipped families per `concurrent-analysis.md` § 5 sub-category prioritization (lock-free data structures): 5.2 Cancellation (no async), 5.8 Wakeup (no parker/condvar). Included: 5.1 Thread Interleaving (universal), 5.4 CAS spurious, 5.5 Memory ordering, 5.6 ABA / pointer reuse, 5.7 Caller misuse.

### Coverage summary

- **Commits analyzed deeply**: 11 substantive bug-fix commits (out of 178 deque commits and ~36 keyword-matched).
- **Issues read with full discussion**: 10 (Issues #589, #609, #646, #688, #730, #846, #869, #957, #1116, #1148).
- **PRs read with full discussion**: 11 (PRs #726, #728, #779, #829, #849, #855, #871, #903, #1159, #1216, #1233).
- **Confirmed bugs (fixed)**: 7 (CVE-2021-32810, MaybeUninit migration, dest_buffer typo, FIFO↔LIFO reversal, Block stack-overflow, Block null-alloc, ManuallyDrop unsoundness).
- **Confirmed open / unresolved**: 1 (#869 MacOS M1 race, mitigated only).
- **False positives excluded**: 5 (TSan noise, language-level UB at LLVM, upstream rustc bugs, infrastructure issues, language-only patterns).
- **Suspected fragility worth modeling**: 7 (SU-1 through SU-7).
- **Total deep-analysis findings classified**: 13 by-design + 7 suspected + 5 false-positive = 25 findings across 2,233 LOC.

### Recommended verification methods

| Bug ID | Method | Justification |
|--------|--------|---------------|
| SU-1 | TLA+ model checking | Asymmetric site; safety hinges on resize semantics — model-checkable. |
| SU-2 | TLA+ invariant + code-review docs | Make the invariant explicit. |
| SU-3 | TLA+ model checking | Walk-through suggests safe; verify under interleaving. |
| SU-4 | TLA+ model checking + code review | Verify epoch::pin contract. |
| SU-5 | TLA+ model checking | Walker invariant is non-obvious. |
| SU-6 | Code review (post-`1015b21d` merge) | Liveness, not safety; will be moot once strong-CAS is in main. |
| SU-7 | TLA+ model checking | Fold into Family A. |
| FP-1..5 | None — exclusions documented | Out of TLA scope. |

### Concluding remark

crossbeam-deque is mature and well-vetted; the CVE-2021-32810 fix and subsequent MaybeUninit migration close the most critical historical race. The remaining attack surface is (a) the asymmetric absence of the buffer re-check at deque.rs:1083 — currently safe but reliant on undocumented resize-preserves-indices invariant, (b) the Le et al. 2013 ordering bridges which have not been adversarially modeled, (c) the Injector block-lifecycle walker invariant which is non-obvious and refactor-fragile, (d) the open M1 race (#869). All four are excellent TLA+ targets and align with the prior-verification-gap noted in the case-study brief: **no fault injection at all** in prior runs.
