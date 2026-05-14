# Confirmed Bug Report — tokio-broadcast_2 (Round 2)

## Summary

- Total findings reviewed: **17** (4 MC hunts, 2 Case A spec fixes, 10 model-checkable pending items M1–M10, 5 code-review-only items R1–R5; the 4 MC hunts collectively cover M1–M10)
- Reproduced (new bugs): **0**
- Confirmed (code audit, reproduction failed): **0**
- False positives / not bugs: **7** (2 Case A spec fixes + R2/R3/R4/R5 + M5 reopen-by-design)
- Filtered (theoretical / out-of-scope / spec-granularity): **5** (R1 theoretical, M1/M2 spec granularity, M9 carry-forward, M10 not modeled)
- Carry-forward (already reproduced in Round 1): **2** (#109 u64 panic, #110 drop leak — out of scope)

**Bottom line: this round produced zero new confirmed implementation
bugs in `tokio::sync::broadcast`.** The four bug-family hunts (F1
drop/close races, F2 caller misuse, F4 memory ordering on
`Waiter.queued`, F5 slot reuse) ran to completion (or hit infrastructure
limits — disk quota, JVM crash) at BFS depths 40–80 and 10K–189M
distinct states, and every safety invariant held after two Case A
invariant calibrations. No new reproduction tests were required because
no new bug was identified that survives the Phase 0 filters of the
bug-confirmation skill.

The `repro/` directory contains only a README explaining the empty
state. The two carry-forward wraparound bugs (#109, #110) are explicitly
out of scope per the modeling brief — they were already reproduced in
Round 1.

---

## How findings were filtered

Each finding was passed through the Phase 0 system-level-consequence
filter:

1. **Path ≠ bug.** Was the worst case "an internal value is unexpected,
   but downstream code already validates"?
2. **Name the observable harm.** Could a user, operator, or other
   component see something go wrong?
3. **Developer intent.** Do comments / tests / PR discussions show this
   is by design?

Findings that failed any filter, were already known historical bugs
fixed in current code, or are theoretical-only (e.g. require ≈ 580
years of continuous sends) are reported below as "not a bug" with
justification rather than dropped silently.

---

## MC hunt results — F1, F2, F4, F5

| Hunt | Mode | States | Diameter | Result |
|---|---|---|---|---|
| F1 drop/close races | BFS | 9.4M / 2.2M | 80 | All invariants hold (after Case A fix 1) |
| F2 caller misuse | BFS | 1.05B / 189M | 50 | All invariants hold (after Case A fix 2) |
| F4 memory order on queued | BFS | 27,721 / 10,023 | 40 | All invariants hold |
| F5 slot reuse | BFS | ~750M / 181M | 65 | All invariants hold |
| MC.cfg convergence | Sim | 722M / 3M traces | n/a | All invariants hold |

**Status: NO BUG.** Every invariant including
`NoUseAfterFree_Waiter`, `NoSlotLeak`, `NoDoubleRelease`,
`NoSpuriousLagged`, `SubscribeRespectsSendBoundary`,
`CloseReopenSemantics`, `WaiterQueuedConsistency`,
`ReceiverCountConsistency`, and the post-fix
`ConcurrentDropCloseIdempotent` and
`RxCntPositiveImpliesNotPermanentlyClosed` held under the configured
adversarial harness.

The user's brief explicitly highlighted "5.7 caller misuse + 5.5 memory
ordering on slot publication" as the priority for this run; both
families were covered (F2 and F4 respectively) with no violations.

---

## Spec-side fixes (NOT implementation bugs)

These are Case A — invariants too strong relative to the implementation.
The implementation behavior is correct and is exactly what the developers
expect; the original invariant formulation was overly idealized.

### Spec Fix 1: `ConcurrentDropCloseIdempotent`

- **Source**: MC counterexample (4 states, F1 hunt)
- **Status**: FALSE POSITIVE (spec calibration)
- **Severity**: N/A
- **Location**: `tokio/src/sync/broadcast.rs:1067-1073` (Sender::Drop)
- **Description**: The original invariant required
  `(tailClosed ∧ tailRxCnt > 0) ⇒ closeReason ∈ {none, all_receivers_dropped}`.
  The MC counterexample showed a 4-state trace where the last sender
  drops before the last receiver, producing a transient
  `tailClosed = true ∧ tailRxCnt = 1 ∧ closeReason = "all_senders_dropped"`
  state. This is the implementation's *intended* behavior:
  `Sender::Drop` calls `close_channel()` unconditionally when
  `num_tx.fetch_sub` returns 1, regardless of whether receivers are
  still alive — they will see `Closed` errors on subsequent recv calls.
- **Why not a bug**: Phase 0 filters 1 and 3 — no system-level
  consequence (downstream `recv` correctly returns `Closed`), and
  developers explicitly designed this path (the unconditional
  `close_channel` is documented behavior).
- **Resolution**: Reformulated to the structural consistency check
  `closeReason = "all_senders_dropped" ⇒ numTx = 0`.
- **Reproduction test**: N/A — not a bug.

### Spec Fix 2: `RxCntPositiveImpliesNotPermanentlyClosed`

- **Source**: MC counterexample (4 states, F2 hunt)
- **Status**: FALSE POSITIVE (spec calibration)
- **Severity**: N/A
- **Location**: same site, `broadcast.rs:1067-1073`
- **Description**: Same root shape as Fix 1 — the original formulation
  excluded the transient `(tailClosed ∧ closeReason = "all_senders_dropped" ∧ tailRxCnt > 0)`
  window. Implementation legally allows receivers to remain alive after
  the channel is closed-by-sender-drop.
- **Resolution**: Reformulated as
  `(tailRxCnt > 0) ⇒ closeReason ≠ "all_receivers_dropped"`. The
  reopen path at `new_receiver` (broadcast.rs:1004 in the upstream
  numbering) flips `closed = false` when `rxCnt = 0`, so a
  receiver-drop close cannot coexist with any live receiver.
- **Reproduction test**: N/A — not a bug.

---

## Findings vs. modeling brief § 6.1 (M1–M10)

| ID | Finding | MC status | Code-audit verdict |
|----|---------|-----------|-------------------|
| M1 | Recv::Drop Acquire-load short-circuit; downgrade should violate `NoUseAfterFree_Waiter` | Not violated under F4 hunt | **FILTERED** — spec atomicity of `NotifyRx_DrainStep_Take` (one action removes from `tailWaiters`, adds to `notifyExtracted`, clears waker and queued) prevents the adversary from reaching the historical PR #6298 race window. Spec-granularity limitation; the bug PR #6298 fixed has been fixed in current code. |
| M2 | Reordering `notify_rx`'s take-waker / clear-queued | Not modelable | **FILTERED** — actions are atomic by construction; would need a sub-step split to model. The reordering is prevented by source code structure (single function with explicit ordering at the comment block at `broadcast.rs:1025-1027` upstream). |
| M3 | Subscribe-while-send adversary | Not violated (189M states, depth 50) | **NO BUG** — `Sender::send` snapshots `rem = rx_cnt` *before* a new subscriber can increment it (broadcast.rs:631-666); the new subscriber correctly does not receive that send. Verified consistent with the published `subscribe` semantics. |
| M4 | Drop-while-send `NoSlotLeak` | Not violated | **NO BUG** — both release paths (overwriting send via `Option::replace`, and `RecvGuard::Drop` `rem.fetch_sub`) correctly cooperate. |
| M5 | Resubscribe after sender-drop close (PR #4814 pattern) | Allowed by spec and by impl | **BY DESIGN** — Phase 0 filter 3: developers' tests assert this exact behavior. The original `ConcurrentDropCloseIdempotent` (above) captured an idealized invariant the impl does not satisfy by design. The current impl correctly distinguishes `closeReason = receivers_dropped` (reopenable via subscribe) from `closeReason = senders_dropped` (permanent). |
| M6 | `Sender::closed()` future under toggle adversary | Not directly checked | **NOT MODELED** — Sender::closed modeled abstractly; no observed liveness violation. Code review confirms the `register-notified-then-check-closed` idiom at `broadcast.rs:889-903` upstream is correct because `Notify::notified` snapshots a counter and `Notify::notify_waiters` bumps under its own lock. |
| M7 | `Receiver::Drop` drain loop termination | Bounded structurally | **NO BUG** — drain loop bounded by `rxDropUntil` snapshot; the `<` comparison fix from PR #3434 is in place. |
| M8 | Post-Lagged next-recv classifier | Not violated under F5 hunt (181M states, depth 65) | **NO BUG** — three-branch classifier at `broadcast.rs:1252-1322` upstream correctly handles Hit/Empty/Lagged. |
| M9 | Wraparound classifier soundness | Out of scope | **CARRY-FORWARD** — Round 1 already reproduced #109 panic and #110 leak. Per the brief, do not re-do these. |
| M10 | `is_closed()` true while `tail.closed` false (Sender::Drop window) | Liveness-bounded | **NOT A BUG** — the transient window between `num_tx.fetch_sub(1)` returning 1 and `close_channel()` being called is observable but is bounded by the unconditional `close_channel()` call that immediately follows. R5 (below) recommends a code comment cross-reference, no code change. |

---

## Code-review-only items (R1–R5)

| ID | Description | Status | Justification |
|----|-------------|--------|---------------|
| R1 | `Receiver::len` at `broadcast.rs:1351-1354` (instrumented) does plain subtraction `(next_send_pos - self.next) as usize` instead of `wrapping_sub`. Theoretically panics in debug at u64 wraparound. | **FILTERED — theoretical only** | Phase 0 filter 2: no observable harm at realistic scales. At 1 send/ns it would take ≈ 580 years to reach `u64::MAX`. The Round 1 wraparound bugs (#109/#110) targeted real positions exhausted by the ring math, not this counter. The modeling brief explicitly recommends "code-review fix" only, "Not modelable at realistic scales." |
| R2 | `Sender::len` / `is_empty` use SeqCst on `slot.rem` while holding slot lock. | **NOT A BUG (inert)** | Memory ordering is overkill but correct under the lock; no observable harm. |
| R3 | Two structurally-different `closed` states (sender-drop permanent vs. receiver-drop reopenable) share one bool. | **NOT A BUG (formalization)** | The `CloseReason` extension formalizes for spec purposes; the implementation correctly uses `num_tx == 0` and `rx_cnt == 0` to disambiguate. Spec Fix 1 already accounts for this. |
| R4 | `MAX_RECEIVERS = usize::MAX >> 2` panic on `subscribe()`. | **NOT A BUG (intentional)** | Phase 0 filter 3: documented in code as a defensive cap; cannot be reached at realistic scales (would require `2^62` live receivers on a 64-bit platform). |
| R5 | Transient `num_tx == 0 ∧ ¬tail.closed` window observable via `is_closed()` (Sender::Drop between `fetch_sub` and `close_channel`). | **NOT A BUG (benign-transient)** | Phase 0 filter 1: window is bounded by the immediately-following `close_channel()` call; no consumer of `is_closed()` makes a decision that survives the window without re-checking. Recommendation is code comment only, no behavior change. |

---

## Reproduction tests

`repro/` contains only a `README.md` explaining the empty state.

**Why no test files**: the bug-confirmation skill mandates reproduction
for each *NEW confirmed bug*. This round identified zero new confirmed
bugs that survive the Phase 0 filters, so there is no candidate
requiring a reproduction. The two Round-1 wraparound bugs are
out-of-scope carry-forwards and are not re-reproduced here per the
brief.

If a future round identifies a new bug, the `repro/` directory should
contain `test_bug<N>_<name>.{rs,sh}` files that:
1. Trigger via `tokio::sync::broadcast` public APIs only (no illegal
   state injection).
2. Use real multi-thread scenarios for concurrency bugs (small `sleep`
   or failpoint timing aids permitted to widen race windows).
3. Are actually executed with output captured.

---

## Methodology compliance notes

- **Phase 0 (system-level consequence test)**: applied to all 17
  findings; rejection reasons recorded above per finding.
- **Phase 1 (code audit)**: source code at
  `artifact/tokio/tokio/src/sync/broadcast.rs` was inspected for the R1
  finding and at the locations referenced by the modeling brief
  (Sender::Drop close window, Sender::send rem snapshot, recv_ref
  classifier, Receiver::len). Line numbers in the artifact differ from
  upstream because of inserted `tla::emit_generic` instrumentation
  calls, but call structure matches.
- **Phase 1.5 (developer intent)**: developer intent for the Case A
  invariants was inferred from the unconditional `close_channel()` call
  at `Sender::Drop` and the `closed = (rx_cnt == 0)` reopen rule at
  `new_receiver` — both are explicit in the source and were the
  motivation for the original PR #4867 and #7629 fixes.
- **Phase 2 (reproduction)**: not triggered — no new confirmed bugs to
  reproduce.

---

## Recommendations

1. **No code changes required** for the implementation in this round.
2. **Optional code comment additions**:
   - `Receiver::len`: convert plain `-` to `wrapping_sub`, even though
     unreachable at realistic scales (R1).
   - Add a comment near `Sender::Drop` cross-referencing the
     `NumTxZeroEventuallyClosed` invariant (R5).
3. **Future MC investment**: consider splitting
   `NotifyRx_DrainStep_Take` into sub-steps if you want to retroactively
   confirm M1/M2 (would only re-find PR #6298 / PR #5578 patterns,
   already fixed). Lower priority.
