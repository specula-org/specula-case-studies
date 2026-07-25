# Confirmed Bug Report — arc-swap_2

**Date**: 2026-05-07
**Artifact**: `vorner/arc-swap` at commit `d5dd00c` (post-1.8.2)
**Source of findings**: `bug-report.md` (MC) + `modeling-brief.md` (code review)
**Methodology**: `bug-confirmation/guide.md` Phase 0–2

---

## Summary

| Metric | Count |
|--------|-------|
| Total findings reviewed | 5 MC + 5 code-review pending = 10 |
| **New bugs confirmed in current code** | **0** |
| **Reproduced** | 0 |
| Confirmed-historical (already fixed in HEAD) | 5 |
| False positives (current SC labels prevent the bug) | 5 |
| Pending-verification items kept as code-review-only | 5 (CR1–CR5, doc/clarity) |

The MC pass deliberately constructs counterexamples by running the
`MCRelaxOrdering(site)` adversary, which downgrades one of nine
SC-labelled atomic operations per execution. Each violation reproduces a
**historical** bug class that an upstream fix commit already addresses;
the *current* code in the artifact passes BFS-exhaustive checks at
depths 78 (base config) and 248 (Family B / D hunting configs) without
any violation when `MaxOrderingGaps = 0`.

Per the bug-confirmation guide, historical bugs that map to existing
issues/PRs do **not** require new reproduction tests — the upstream
fixes serve as confirmation. The `repro/` directory is intentionally
empty (see `repro/README.md`).

### Code-audit verification of HEAD

| SC site (modeling brief)            | Current code label | Status |
|-------------------------------------|--------------------|--------|
| `debt/list.rs` — `LIST_HEAD.load`   | `SeqCst`           | ✅ load-bearing fix `d849a2d` present |
| `debt/list.rs:183` — head CAS       | `SeqCst, SeqCst`   | ✅ |
| `debt/list.rs:162` — claim CAS      | `SeqCst, SeqCst`   | ✅ |
| `strategy/hybrid.rs:44` — fast load | `Relaxed` (by design, paired with confirm SC below) | ✅ |
| `strategy/hybrid.rs:52` — confirm load | `SeqCst`        | ✅ fix `6b644ff` (closed #76) implicit |
| `strategy/hybrid.rs:60` — `T::from_ptr(confirm)` (not `ptr`) | uses `confirm` | ✅ fix `63fa111` present |
| `strategy/hybrid.rs:83` — fallback candidate-load | `SeqCst` | ✅ fix `d5dd00c` present |
| `debt/mod.rs:77` — `Debt::pay` CAS  | `AcqRel, Acquire` | ✅ fixes `bd5d327` + `cccf354` present |
| `strategy/hybrid.rs:232` — CAS storage  | `SeqCst, Relaxed` | ✅ |

`git log` confirms all five fix commits (`bd5d327`, `cccf354`,
`d5dd00c`, `63fa111`, `d849a2d`) are in HEAD.

---

## Finding 1: MC-A1 / MC-E1 — Stale `LIST_HEAD` snapshot under relaxed `LIST_HEAD.load`

- **Source**: MC (counterexample at BFS depth 14, configs `MC_hunt_familyA.cfg`, `MC_hunt_familyE.cfg`)
- **Status**: **FALSE POSITIVE for current code / CONFIRMED historical (already fixed)**
- **Severity in current code**: None (label is `SeqCst`); historical: High (UAF after writer return)
- **Location**: `artifact/arc-swap/src/debt/list.rs:102`
- **Description**: `Node::traverse` walks the per-thread linked list. If `LIST_HEAD.load` is downgraded below `SeqCst`, the writer's snapshot of "active reader nodes" can predate a freshly-prepended node's debt slot store, so `pay_all` skips a still-valid debt and the writer subsequently frees the Arc while a reader still references it.
- **MC trigger scenario**: `MCPickRelaxSite("ListHeadLoad")` selects a strict subset of live nodes for `wToVisit`, dropping the reader thread; writer drains the visited subset and returns with one slot still holding `wOldAddr`.
- **Why it is a false positive in HEAD**: The current code labels the load `SeqCst` (`debt/list.rs:102`). Verified by direct read of the source. The MC adversary only triggers the violation by *deliberately* downgrading this label.
- **Developer evidence**: Commit `d849a2d` ("Use SeqCst in debt-lists") and the inline comment on lines 94–101 ("we need to see the newest version of the list … `-> SeqCst`") show the maintainer explicitly considers this label load-bearing. Issue #164 (production crash on 389-ds) is the documented historical incident this bug class corresponds to.
- **Reproduction**: Not required (historical class fixed in HEAD).
- **Recommendation**: Keep `SeqCst` on `debt/list.rs:102`; add a regression-test note flagging the fix commit.

---

## Finding 2: MC-A2 — Multi-site SC-relaxation coverage

- **Source**: MC (`-C` continue-on-error mode of Family A; 23,942 `NoUseAfterFree` + 8,521 `PayAllCompleteness` violations across nine SC sites)
- **Status**: **FALSE POSITIVE for current code / negative confirmation** that every named SC label is load-bearing
- **Severity in current code**: None (all sites are `SeqCst` or stronger as required); historical: same as Finding 1 (UAF)
- **Locations** (all `SeqCst` in HEAD):
  - `debt/mod.rs:77` (`DebtPaySuccess` / `DebtPayFailure` — `AcqRel/Acquire`, fix PR #195/`bd5d327` + `cccf354`)
  - `debt/list.rs:102` (`ListHeadLoad`, fix `d849a2d`)
  - `strategy/hybrid.rs:83` (`FallbackLoad`, fix `d5dd00c`)
  - `strategy/hybrid.rs:52` (`FastConfirmLoad`, fix `6b644ff`)
  - `debt/helping.rs` (`ConfirmHelping`, `ControlSwap`)
  - `debt/fast.rs` (`FastSlotSwap`)
  - `lib.rs:483` (`WriterSwap`)
- **Description**: Under `MCRelaxOrdering` with `-C`, every named SC site shows up in counterexamples ≥326 times in 15 minutes. None violates with no relaxation.
- **Why it is a false positive in HEAD**: All sites carry the documented SC labels. The MC adversary downgrades them artificially.
- **Reproduction**: Not required (verifies labels are load-bearing, not a bug in HEAD).
- **Recommendation**: This is a positive result for the maintainer — the SC labels are documented, comment-explained, and provably necessary. No code change.

---

## Finding 3: MC-B0 — Allocator-reuse ABA on stored pointer

- **Source**: MC (Family B, BFS exhaustive at depth 248 / 7.5M distinct states)
- **Status**: **NO BUG**
- **Severity**: N/A
- **Locations**: `strategy/hybrid.rs:54-71` (fast-path `attempt`); `strategy/hybrid.rs:75-103` (fallback)
- **Description**: When a freed Arc's address is reallocated, numeric pointer comparison succeeds but provenance differs.
- **Why it is a non-finding**: The post-`63fa111` fast path uses `T::from_ptr(confirm)` (where `confirm` is the second SC load) rather than the original `ptr` (Relaxed load). The captured generation matches the live allocation. Spec captures pointer identity as `<addr,gen>`; no `NoTornGuardState` violation under any explored scheduling.
- **Reproduction**: Not required.
- **Recommendation**: Keep using `confirm` (not `ptr`) in `Self::new(...)` at `hybrid.rs:60`. Existing comment on lines 57–59 already explains the provenance hazard.

---

## Finding 4: MC-D0 — Generation wraparound + cooldown

- **Source**: MC (Family D, BFS exhaustive at depth 248 / 7.5M distinct states)
- **Status**: **NO BUG**
- **Severity**: N/A
- **Locations**: `debt/helping.rs:191-213`, `debt/list.rs:115-141`
- **Description**: Helping-path generation increments by 4; on wrap to 0, owning thread sends node to `NODE_COOLDOWN` and surrenders ownership. Other threads can claim only after `active_writers == 0`.
- **Why it is a non-finding**: The spec exercised `MaxHelpGen=4` (wrap to 0 in 1–2 steps). `compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)` plus the `active_writers == 0` guard for `COOLDOWN→UNUSED` is sufficient. No double-claim, no stale-help-across-wrap. Caveat: the *state-level* `CooldownReleaseObservesZero` invariant was relaxed during convergence (Round 1 changelog) because the implementation legitimately permits `nodeState=UNUSED ∧ activeWriters>0` when a writer holds a stale `wToVisit` snapshot of "live nodes"; the corresponding *transition-level* guard is still enforced. The relaxed state invariant was a spec issue, not a code bug.
- **Reproduction**: Not required.
- **Recommendation**: None. Maintainer's design comment (`debt/helping.rs:54-75`) is the longest in the codebase and is now backed by an exhaustive proof at modelled bounds — worth referencing the TLA spec from that block (CR5).

---

## Finding 5: MC-C0 — Adversarial caller (Guard lifecycle, raw-pointer CAS)

- **Source**: MC (Family C, BFS depth 39 / 48M distinct states + 535M-state simulation, 30 min)
- **Status**: **NO BUG within explored coverage** (BFS aborted on disk quota, not exhausted; no violation found in either BFS or simulation)
- **Severity**: N/A
- **Locations** (modelled): `lib.rs:191-193` (`Guard::into_inner`), `strategy/hybrid.rs:106-127` (`Drop`), `strategy/hybrid.rs:217-238` (`compare_and_swap`), `as_raw.rs:60-72` (raw-pointer impls)
- **Description**: The brief flagged this as the gap from the prior round. Adversarial caller actions modelled: `SendGuard`, `IntoInner`, `DropArcSwap`, `CompareAndSwap` with `current_kind ∈ {Arc, Guard, RawFresh, RawStale}`.
- **Why it is a non-finding**:
  - Guard `Send` + drop on different thread: the debt slot is `&'static`, so the slot identity is preserved; `Debt::pay` is global and works from any thread.
  - `into_inner` + `Arc::clone` fork: `into_inner` performs `T::inc` and `debt.pay`, leaving no stale slot reference; `From<Guard<Arc<T>>>` is derived from this path.
  - `compare_and_swap` with `RawStale`: documented and intentional. The `CASIntendedSemantics` invariant explicitly carves out raw-stale callers; for `Arc`/`Guard` callers the semantics hold.
  - `DropArcSwap` overlapping reader: `ArcSwap::Drop` requires `&mut self` and is the caller's precondition; the spec correctly classifies this as a non-bug branch (the `MCDropArcSwap` action only fires when no reader has an `&self` borrow open in the harness, mirroring borrow-check at the API level).
- **Caveat**: BFS aborted at depth 39 (TLC's offheap state-pool disk quota), so coverage is bounded, not exhaustive. The 30-minute simulation did not extend the diameter beyond 100. Stronger adversaries (multiple concurrent `Drop`s, larger guard pools, ordering relaxation × caller misuse) were not run.
- **Developer evidence**: Issue #89 explicitly documents that holding a Guard across `.await` is safe by design. Issue #199 (Cache shareability) is API design, not a protocol bug. Issue #117 (apparent leak) is documented as per-thread retention, not a leak.
- **Reproduction**: Not required (no violation found).
- **Recommendation**: Document the raw-pointer ABA hazard explicitly on `compare_and_swap` (CR2 in the modeling brief — `lib.rs:506-513` doc comment). Already noted as code-review-only.

---

## Code-review-only findings (CR1–CR5, from modeling brief §6.3)

These are documentation-clarity recommendations from the modeling-brief, not bugs. Listed for completeness; none require reproduction or code-fix.

| ID  | Location | Recommendation |
|-----|----------|----------------|
| CR1 | `cache.rs:158-168` (`Cache::revalidate`) | Add note on best-effort revalidate liveness contract (Relaxed staleness). |
| CR2 | `lib.rs:506-513` (`compare_and_swap` doc comment) | Add §"ABA hazard for raw-pointer callers" — documented in `as_raw.rs` examples but not on the `compare_and_swap` doc itself. |
| CR3 | `lib.rs:337-347` (`ArcSwap::Drop`) | Comment that the reentrant load inside `wait_for_readers` is safe under `&mut self` Drop. |
| CR4 | `debt/list.rs:6-9` | Already documents that nodes are never freed; no action. |
| CR5 | `debt/helping.rs:54-75` | Comment-only: cite the TLA spec once it lands. |

---

## Test-verifiable items (TV1–TV4)

These are stress/unit-test recommendations, not bugs. Out of scope for this round — the bug-confirmation pass concerns model-checked or audited findings, and no MC violation aligns with these.

---

## Conclusion

The arc-swap_2 round-2 spec exercised every bug family identified in the
modeling brief, including the explicit Family-C gap that produced bugs
in the structurally similar `left-right` system. Result:

- **Five MC violations**, each a historical-class reproduction under the
  `MCRelaxOrdering` adversary. Every fix commit is in HEAD; the spec
  serves as a regression check that downgrading any single SC label
  re-introduces a UAF. **No new bug.**
- **Two BFS-exhaustive families** (B, D) at depth 248 / 7.5M distinct
  states with no violation. **No bug.**
- **One bounded-coverage family** (C, adversarial caller): 48M BFS
  states + 535M simulation states with no violation. **No bug found,
  not exhaustive** — would benefit from larger guard/swap budgets or
  combined ordering+caller adversaries in a future round.

Per the bug-confirmation methodology, no reproduction tests are
required. The `repro/` directory contains a `README.md` documenting
this conclusion.
