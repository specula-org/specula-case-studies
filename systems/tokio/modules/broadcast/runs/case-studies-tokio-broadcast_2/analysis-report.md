# Analysis Report — tokio `sync::broadcast`

Detailed audit trail of the Phase 1–3 investigation that backs `modeling-brief.md`.

---

## Phase 1: Reconnaissance

### Repository

- Local clone: `/home/ubuntu/Specula/case-studies/tokio-broadcast_2/artifact/tokio`
- Upstream: `tokio-rs/tokio`
- Tag at HEAD: `ee4de818` (2026-04 era), branch `master`.

### Core file

- `tokio/src/sync/broadcast.rs` — 1,759 lines; ~1,720 excluding the `mod tests` block at the bottom.
- Auxiliary types referenced:
  - `tokio::sync::Notify` (used as `notify_last_rx_drop`).
  - `tokio::util::linked_list::{LinkedList, GuardedLinkedList, Link, Pointers}` for the intrusive waiter list.
  - `tokio::util::WakeList` for batched waker delivery.
  - `tokio::loom::cell::UnsafeCell`, `tokio::loom::sync::{Arc, Mutex, MutexGuard, atomic::{AtomicBool, AtomicUsize}}` (loom shims).

### Primary structures

| Type | Fields | Lock discipline |
|---|---|---|
| `Shared<T>` (341-359) | `buffer: Box<[Mutex<Slot<T>>]>`, `mask: usize`, `tail: Mutex<Tail>`, `num_tx`, `num_weak_tx`, `notify_last_rx_drop` | Per-slot Mutex + per-channel Tail Mutex. |
| `Tail` (361-374) | `pos: u64`, `rx_cnt: usize`, `closed: bool`, `waiters: LinkedList<Waiter>` | Tail Mutex. |
| `Slot<T>` (376-394) | `rem: AtomicUsize`, `pos: u64`, `val: Option<T>` | Slot Mutex; `rem` mutated under lock except for `fetch_sub` in `RecvGuard::Drop`. |
| `Waiter` (396-409) | `queued: AtomicBool`, `waker: Option<Waker>`, `pointers`, `_p` | `queued` is the only cross-lock atomic; `waker` is mutated only under tail lock. |
| `Sender<T>`, `WeakSender<T>`, `Receiver<T>`, `Recv<'a, T>`, `WaiterCell`, `RecvGuard<'a, T>` | wrappers | — |

### Public API surface

`Sender`: `new`, `subscribe`, `send`, `len`, `is_empty`, `receiver_count`, `same_channel`, `closed` (future), `strong_count`, `weak_count`, `downgrade`. Plus `Clone`, `Drop`.

`Receiver`: `len`, `is_empty`, `same_channel`, `try_recv`, `recv` (async), `blocking_recv`, `resubscribe`, `is_closed`, `sender_strong_count`, `sender_weak_count`. Plus `Drop`.

`WeakSender`: `upgrade`, `strong_count`, `weak_count`. Plus `Clone`, `Drop`.

### Concurrency model

- Mutex-coordinated ring buffer (capacity rounded up to power of two; mask).
- Each send: lock `Tail` → snapshot `pos`, `rem` → bump `pos` → lock slot at `idx = pos & mask` → write `pos`, `rem`, `val` → drop slot → call `notify_rx` (still holds tail).
- Each recv: lock slot → if `pos` matches, advance `next` and return `RecvGuard`; else drop slot → lock tail → re-lock slot → re-check → either Empty (park waiter), Lagged (skip ahead), or Hit.
- Wakeups: `notify_rx` drains `tail.waiters` into a `GuardedLinkedList`, batches wakers into `WakeList`, releases tail, calls `wake_all`, reacquires tail; loops until list empty.
- `Recv::Drop` uses an `Acquire`-load fast path on `Waiter.queued` to skip the tail lock when the waiter is already taken.

### Category classification

**Category B — Concurrent / Lock-Free / Runtime; sub-category: Channels / Message Passing**.

Justification: All bugs in history are interleavings of `send`/`recv_ref`/`Recv::drop`/`notify_rx` plus a few cross-variable ordering concerns (Acquire/Release on `queued`, AcqRel on `num_tx`). No network, no disk, no protocol state machine. This squarely fits the channels row of `concurrent-analysis.md` §5 prioritization table — primary families are 5.2 (cancel/drop/close) and 5.7 (caller misuse) per that table, plus 5.5 (memory ordering) per the user's brief.

---

## Phase 2: Bug Archaeology

### 2.1 Coverage Statistics

- **Git commits touching `tokio/src/sync/broadcast.rs`**: 81 total. Significant correctness fixes: 14. Reverts: 2 (#2348 reverts #2302; #3020 reverts #2933). Pure docs/style/refactor: 60+ (excluded with explicit reason).
- **GitHub issues collected** (10 keyword searches × broadcast/race/lag/close/drop/cancel/wake/deadlock/panic + PR list): ~70 unique items.
- **Issues + PRs deeply read** (full thread via `gh issue view --comments`): **30+**.
- **Confirmed bugs**: 12 (most fixed; one — #7350 capacity-overflow — has only a doc fix).
- **Open bug-fix-intent issues** at time of this analysis: **0** (all open broadcast-tagged items are feature requests, perf asks, or already-discussed dups).

### 2.2 Significant Fix Commits (chronological)

| Hash | PR | Subject | Mechanism | Family |
|---|---|---|---|---|
| `f9ea576c` | #2135 | Fix broadcast bugs | Lost wakeup: `condvar.notify_one()` outside tail mutex; sender count > buffer.len() broke lock invariant. Loom test added. | Memory ordering / lost wakeup |
| `826fc21a` | #2302 | Keep lock until sender notified | Misread fix. **Reverted** by #2348. | (reverted) |
| `5c71268b` | #2348 | Revert #2302 | Originally `let _ = tail.lock()` did drop guard immediately; replaced with `mem::drop(...)`. | Reverted |
| `a8195848` | #2448 | Fix slow receivers | Slot-reuse on close: capacity-1 channel writing a sentinel overwrote the only real value; spurious Lagged. Introduced `Tail.closed` flag plus `CLOSED` lock-bit on the next slot. | Slot reuse |
| `fb7dfcf4` | #2509 | Use intrusive list for waiters | Resource leak: receiver wakers stored in atomic stack of allocated nodes, drained only by sends; piled up indefinitely if no send. Major rewrite. | Cancellation / Drop (waiter leak) |
| `fb28caa9` | #2933 | Implement Clone for Receiver | (later reverted) | — |
| `8bfb1c92` | #3020 | Revert Clone for Receiver | Semantic ambiguity (copy-state vs subscribe-at-tail). | Caller misuse |
| `7d5b12c5` | #3434 | Fix `Receiver::Drop` panic | Wraparound: `until = tail.pos` snapshot can be passed by `self.next` due to lag + concurrent send. Changed `!=` to `<`. | u64 wraparound |
| `9d9488db` | #4867 | Remove slot-level closed flag | Off-by-one closure: subscribe-after-close hung forever because separate per-slot `closed` flag inconsistent with `Tail.closed`. Unified to single source. | Caller misuse / close race |
| `8497f379` | #5578 | Avoid deadlocks with custom wakers | `notify_rx` woke wakers under tail lock; custom `Waker::drop` re-entered `tx.send()` → self-deadlock. Also `recv_ref` replaced waker while locks held. | Cancellation / re-entrant Drop |
| `3dd5f7ae` | #5925 | Move waiters to separate list before waking | Quadratic notify: receivers re-queued mid-loop; bounded loop by initial waiter count via `GuardedLinkedList`. | Performance + lifetime |
| `75361320` | #6298 | AtomicBool in broadcast channel future | `Waiter.queued` was non-atomic `bool`; `Recv::drop` raced with `notify_rx`'s clear under lock. Made atomic with Acquire/Release. | Memory ordering on waiter publication |
| `4b174ce2` | (no PR — direct commit) | Fix cloning value when receiving | RUSTSEC-2025-0023: `T: !Sync` cloned under per-slot RwLock read guard concurrently → UB. Switched to per-slot Mutex; serialize cloning. | Memory ordering / soundness |
| `da292dfb`, `6d1ae628` | #7629 | Close `Sender` in `Sender::new()` | `Sender::new(0)` left `closed=false` despite no receivers; `closed()` future blocked forever. Fix: `closed = (rx_cnt == 0)`. | Caller misuse / state init |

### 2.3 Excluded Commits (with reason)

- **Pure documentation/typos**: #2027, #2037, #2197, #2622, #2731, #2732, #2737, #2838, #3460, #3504, #3892, #4174, #4622, #5306, #5480, #5497, #5820, #6042, #6056, #6081, #6100, #6182, #6377, #6466, #6569, #6804, #6870, #7090, #7100, #7116, #7352, #7452, #7537, #7595, #7654, #7711, #7977, #7984, #7989, etc.
- **Pure refactor / lint / cleanup**: `8656b7b8`, `cc8a6625`, `53707f5d`, `8efa6201`, `2e05399f`, `bd4ccae1`, `21df16d7`, `605ef578`, `8bc21be4`, `d533e05a`, `4daeea8c`, `7a99f87d`, `11f66f43`, `daa89017`, `68710846`, `665f08b5`, `a7896d07`, `8ccf2fb9`, `6f048ca9`.
- **Doctest flake fixes** (no runtime bug): #7090.
- **Feature additions** (not fixes): #2012 (impl Stream), #2898 (API tweaks), #2937 (error module move), #4542 (Receiver::len), #4607 (resubscribe), #4808 (track_caller), #5343 (Sender::len), #5607 (same_channel), #5690 (blocking_recv), #5824 (Sender::new), #6685 (Sender::closed), #7100 (WeakSender), #7900 (WeakSender::closed).

### 2.4 GitHub Issues Deeply Read

| # | Type | Title (abbrev.) | State | Class | Family | One-line summary |
|---|---|---|---|---|---|---|
| 2123 | issue | sync::broadcast buggy | CLOSED | Confirmed bug | wakeup / slot reuse | Lost wakeup via notify outside lock; lock-invariant break when senders > buffer.len. Fixed by #2135. |
| 2134 | PR | Fix sender lost wakeup | CLOSED→superseded | Confirmed fix | wakeup | Superseded by #2135. |
| 2135 | PR | Fix broadcast bugs | MERGED | Confirmed fix | wakeup | Loom test added. Closes #2123. |
| 2425 | issue | Lagged returned when capacity not exceeded | CLOSED | Confirmed bug | slot reuse | Algorithm overeager; fixed in 0.2.21 via #2448. |
| 2448 | PR | Fix slow receivers | MERGED | Confirmed fix | slot reuse | Closes #2425. |
| 2467 | PR | Simplify broadcast channel | MERGED | Refactor | — | Rewrite that fixed misc misbehavior. |
| 2509 | PR | Intrusive list for waiters | MERGED | Confirmed fix | drop / cancel | Removed unbounded waker storage. |
| 2533 | issue | Receiver drop panic | CLOSED | Confirmed bug | drop race | MCRE: drop receiver while sender spamming a 3-cap channel. Fixed by #3434. |
| 3434 | PR | Fix `Receiver::Drop` panic | MERGED | Confirmed fix | drop / wraparound | Lag pushes `next` past `until`; fix changes `!=` to `<`. |
| 4057 | issue | Get nothing if send more than capacity | CLOSED | User error | misuse | Reporter ignored `Lagged`; `while let Ok(...)` exits silently. |
| 4405 | issue | Used capacity of broadcast | CLOSED | Feature ask | — | Per-receiver queue depth clarified. |
| 4621 | issue | Document `channel(0)` panics | CLOSED | Doc | — | — |
| 4625 | issue | Sender doesn't notify on drop | CLOSED | User error | misuse | `let _ = ...;` does NOT drop. Reproduces back to 0.2.5; not a real bug. |
| 4647 | issue | Only some receivers receive | CLOSED | User error | misuse | Sequential `recv` of two channels. |
| 4814 | issue | Resubscribing to closed channel hangs | CLOSED | Confirmed bug | close race | `new_receiver` did not adjust `next` for close marker; `recv()` hung. Fixed by #4867. |
| 4867 | PR | Remove slot-level closed flag | MERGED | Confirmed fix | close race | Closes #4814. |
| 5083 | issue | Receiver skips messages | CLOSED | Disputed | subscribe semantics | Reporter could not produce MCRE. Subscribe-after-send semantics intentional. |
| 5429 | issue | Custom-waker deadlock | CLOSED | Confirmed bug | drop / cancel | `notify_rx` woke under lock; custom waker re-entered `tx.send` → self-deadlock. Fixed by #5578. |
| 5465 | issue | Reduce contention | OPEN since 2023-02 | Perf | — | Help-wanted. No correctness claim. |
| 5479/5482 | issue | High-risk lines: deadlock | CLOSED | Disputed | drop / waker | Static analysis flagged broadcast.rs:915; Darksonn confirmed false positive. |
| 5578 | PR | Avoid deadlocks with custom wakers | MERGED | Confirmed fix | drop / cancel | Closes #5429. |
| 5821 | PR | Use usize instead of u64 | CLOSED (rejected) | Disputed | wraparound | `u64` is exposed via `RecvError::Lagged(u64)`; would be breaking change. |
| 5923 | issue | Quadratic slowdown in send w/ many receivers | CLOSED | Confirmed bug | wakeup | `notify_rx` re-adding receivers; fixed by #5925. |
| 5925 | PR | Stop notifying after we've woken all wakers | MERGED | Confirmed fix | wakeup | Closes #5923. |
| 6015 | issue | Capacity not well-documented | CLOSED | Doc | — | Power-of-two rounding. Doc fix #6042. |
| 6284 | PR | Reduce contention via atomic list | CLOSED | Replaced | perf | Replaced by #6298. |
| 6298 | PR | Don't take tail lock when dropping `Recv` | MERGED | Perf + correctness | drop / cancel | `AtomicBool queued` enables fast path. ~40% improvement at 1k receivers. |
| 6649/6685 | issue/PR | `Sender::closed` Future | merged → reverted (#7087) → re-fixed (#7090, #7629) | Confirmed bug history | close race | `Sender::new()`-without-rx blocked `closed()` future forever. Final fix in #7629. |
| 7232 | PR | Fix cloning value (RUSTSEC-2025-0023) | MERGED | Confirmed unsoundness | memory ordering | T: !Sync cloned without sync. Backports to 1.38.2/1.42.1/1.43.1/1.44.2. |
| 7350 | issue | `channel(usize::MAX/2)` panics | CLOSED | Doc bug | wraparound | Capacity rounding overflow. Doc-only fix. |
| 7629 | PR | Close `Sender::new()` | MERGED | Confirmed fix | close race / state init | Final fix for #6685's regression. |
| 7900 | PR | `WeakSender::closed` | OPEN | Feature | — | — |

### 2.5 Bug Family Summary (historical)

- **Family 1: Cancel / Drop / Close races**: 4 confirmed bugs (#2123/#2135 lost wakeup, #5429/#5578 custom-waker deadlock, #6298 atomic-bool race, #6685 close-future regression sequence ending in #7629). Highest density.
- **Family 2: Adversarial caller patterns**: 3 confirmed (#4814/#4867 resubscribe-after-close, #2533/#3434 drop-panic with concurrent send, #6685/#7629 Sender::new(0) closed-future hang) plus 2 design-defect items (#3020 Clone semantics, #5083 subscribe semantics confusion).
- **Family 3: u64 wraparound**: 1 confirmed in tokio (#3434). 1 disputed proposal (#5821). 1 doc-only (#7350). User notes prior round reproduced 2 internal bugs (#109 panic, #110 leak — internal numbering, not GitHub).
- **Family 4: Memory ordering**: 3 confirmed (#2123/#2135 notify-outside-lock, #6298 queued atomic, #7232 RUSTSEC-2025-0023 T:!Sync clone race). Most surprising recent fix is #7232 (March 2025, public security advisory).
- **Family 5: Slot reuse**: 3 confirmed (#2425/#2448 spurious-Lagged at capacity, #4814/#4867 close marker, #5923/#5925 quadratic notify). All fixed.

### 2.6 Surprising / Notable Findings

1. **Two reverts** confirm fixes were misdirected:
   - #2302 → #2348 (lock-keep "fix" was unnecessary; original `let _ = tail.lock()` already dropped immediately).
   - #2933 → #3020 (Clone for Receiver pulled due to ambiguity).
2. **#4b174ce2 (RUSTSEC-2025-0023) has no PR number**; pushed directly by Carl Lerche on 2025-03-31.
3. **The user's brief mentions "#109 panics, #110 leaks"** as known wraparound bugs; these numbers are NOT in the tokio repo (tokio #109 is "Remove UdpCodec", #110 is unrelated). They refer to this project's internal modeling numbering. The closest tokio analog is PR #5821 (rejected u64→usize swap) and PR #3434 (Drop panic on lag-vs-send race).
4. **No currently-open broadcast bug**. All open broadcast items are features or perf asks.
5. **#5578 (custom-waker deadlock) is the most modeling-relevant for cancellation safety** — its `send_in_waker_drop` test is a clean adversarial scenario.
6. **#2509 fundamentally changed waiter discipline** from atomic-stack to intrusive doubly-linked list. All later memory-ordering fixes (#5578, #5925, #6298, #4b174ce2) operate on this post-#2509 design — pre-#2509 modeling is unrelated.

---

## Phase 3: Deep Analysis

### 3.1 Cancel / Drop / Close (Family 1)

**Scenario A — Recv future dropped while parked.**

`Recv::Drop` (`broadcast.rs:1625-1663`):
1. Acquire-load `queued` at `:1633`. If false, exit.
2. Else lock tail at `:1641`, Relaxed re-load `queued` at `:1648`, if still queued unlink at `:1657`.

`Shared::notify_rx` (`broadcast.rs:992-1056`):
- Drains waiters into `WaitersList` (line `:1007`).
- For each: takes waker first (`:1017`), then `queued.store(false, Release)` (`:1028`). Comment at `:1025-1027` explicitly mandates the order.
- Drops tail at `:1038`, calls `wake_all` at `:1045`, reacquires tail at `:1048`.

**Verification**: `Recv::Drop` Acquire-load synchronizes with `notify_rx` Release-store. If drop sees `queued=false`, the waker has already been moved out of the `Waiter` storage (it's now in the WakeList); the Waiter storage may be freed safely. No use-after-free. **Correct.**

**Scenario B — Receiver dropped while sender is in `notify_rx`.**

`Drop for Receiver` (`broadcast.rs:1548-1574`): locks tail (`:1550`), decrements rx_cnt (`:1552`), snapshots `until = tail.pos` (`:1553`), drops tail (`:1561`), drains via `recv_ref(None)` until `self.next < until`.

The `until = tail.pos` snapshot is taken under the same tail lock as the rx_cnt decrement. Sender's `tail.pos` bump (`:644`) and rx_cnt read (`:640`) happen under the same lock. Therefore:
- Sends linearized before drop's tail-lock acquisition: `tail.pos` includes them, `rem` includes the dropped receiver, drain consumes them.
- Sends linearized after drop's tail-lock release: `rem` excludes the dropped receiver. No leak.

Lagged path inside drain (`:1568-1569`): when `recv_ref` returns Lagged, `self.next` is fast-forwarded to `tail.pos − cap`. Skipped values were already released by overwriting sends via `Option::replace` at `:656`. **Correct, no leak.**

**Scenario C — Last sender drop concurrent with last receiver drop.**

Both serialize through tail. `Sender::Drop` (`:1067-1073`) does `num_tx.fetch_sub(1, AcqRel)`. If returns 1, calls `close_channel` which locks tail and sets `closed = true`. `Receiver::Drop` separately locks tail and sets `closed = true`. Setting closed twice is benign.

There is a **transient window**: between `fetch_sub` returning 1 and `close_channel` running, `is_closed()` (`:1361-1364` reads `num_tx` Acquire) returns true while `tail.closed` is still false. **Benign**, but the spec invariant `NumTxZeroEventuallyClosed` should be modeled.

**Scenario D — `Sender::closed()` future under adversary toggling closed.**

Pattern at `:889-903`:
```
loop {
    let notified = self.shared.notify_last_rx_drop.notified();  // snapshots count
    { let tail = ...lock(); if tail.closed { return; } }
    notified.await;  // resolves immediately if count changed
}
```

Read `notify.rs:565-575, 1148, 1265`: `Notify::notified()` snapshots `notify_waiters_calls`. If `notify_waiters` is called between snapshot and await, the future resolves immediately. Standard register-then-check pattern. **Correct.**

**Scenario E — `Sender::new(0 rx)` initial state.**

After PR #7629, `closed: rx_cnt == 0` at `:569`. So `Sender::new(0)` starts closed; `new_receiver` flips closed = false at `:933` when rx_cnt was 0. **Correct.** No regression.

**Scenario F — Drop ordering Recv vs Receiver.**

`Recv` borrows `&'a mut Receiver<T>` (`:437`). Borrow checker enforces sequential drop. **Correct, not a runtime invariant.**

### 3.2 Adversarial Caller Patterns (Family 2)

**Subscribe-while-send** (`:631-666` + `:924-942`): sender holds tail across the entire critical section (including `notify_rx`'s pre-lock-drop work). new_receiver waits on tail. Two interleavings, both correct:
- Subscribe before send: rx_cnt incremented; sender's snapshot at `:640` includes new receiver; new receiver's `next = tail.pos` is the position the send is about to write; new receiver receives the value.
- Subscribe after send: tail.pos is post-send; sender's `rem` snapshot excluded new receiver; new receiver does not receive that value (per documented semantics at `:17-19`, `:669-670`).

The "racing receiver is faster, slot N not yet written" path: receiver later locks slot, sees mismatched pos, drops slot, re-locks tail (which serializes against in-flight send), re-locks slot. By then send must have committed (slot drop at `:659` precedes tail drop at `:1052`). Empty branch via `next_pos == self.next` at `:1255` correctly applies.

**Drop-out-of-order with un-consumed slots**: drain at `:1563-1573` is bounded; lag-skipped slots are released by overwriting sends, not by lagged drain.

**Mixed close+drop**: idempotent through tail lock.

**Resubscribe after close**: `new_receiver` at `:929-934` reopens by setting `closed = false` if `rx_cnt == 0`. **But** if close was caused by `Sender::Drop` (no senders left), the channel is still effectively unusable for sending — only `WeakSender::upgrade` could resurrect it, and it gates on `num_tx != 0` (`:1085`). So a "reopened" channel with no senders is harmless: receivers can still observe whatever was already buffered, plus eventually get Closed. The `closed` field thus encodes two structurally different states; the `CloseReason` extension in the modeling brief formalizes this.

**try_recv repeated under heavy lag**: traced at `:1252-1322`. Returns Lagged at most once per overflow window; after Lagged, `self.next = tail.pos − cap`; next call hits the slot at that idx (which holds exactly that value) and returns Ok. **Correct.**

### 3.3 Memory Ordering and Slot Reuse (Families 4, 5)

**Slot publication** (`:631-667` send + `:1223-1328` recv_ref): both use the slot Mutex. Mutex acquire-release is sufficient for the slot read after slot lock acquire to see all sender writes. **Correct.** The receiver's `tail` lock acquisition at `:1244` provides a second sync edge with the sender (which holds tail across the whole send). Either edge suffices.

**`slot.rem` access patterns**:
- Sender writes via `with_mut` non-atomic (`:653`) — safe under slot lock.
- `RecvGuard::Drop` `fetch_sub(1, SeqCst)` (`:1715`) — under slot lock; SeqCst overkill but inert.
- `Sender::len` (`:755`) and `is_empty` (`:797`) load with SeqCst under slot lock — also overkill.
- Spec should treat `rem` as plain mutable state under slot lock.

**`Waiter.queued` ordering**:
- `Recv::Drop` Acquire-load (`:1633`) — outside any lock.
- `notify_rx` Release-store (`:1028`) — under tail lock.
- `recv_ref` Relaxed load (`:1283`) and Relaxed store (`:1286`) — under tail lock.
- `Recv::Drop` Relaxed re-load (`:1648`) — under tail lock.

The Acquire/Release pair on `:1633`/`:1028` is the **only** synchronization on the unlocked Recv::Drop short-circuit path. Critical that `notify_rx` takes the waker (`:1017`) BEFORE the Release-store. Documented in `:1025-1027`.

**Slot reuse classifier** (`:1252-1322`):
- `slot.pos == self.next` ⇒ hit.
- `slot.pos.wrapping_add(cap) == self.next` ⇒ slot still holds previous wave at this idx ⇒ Empty.
- else ⇒ Lagged. Fast-forward `self.next = tail.pos − cap`.

Cold-start verification at construction (`:558` initializes slot.pos to `(i as u64).wrapping_sub(cap)`):
- Receiver.next = 0 (first slot empty test): `slot.pos = -cap+i`, `next_pos = i = self.next` for i=0. **Correct.**

u64 wraparound: `missed = next.wrapping_sub(self.next)` (`:1308`). Near 2^64, `missed` is some huge meaningless number but receiver still resyncs to oldest slot. Safety preserved; only the count is misleading.

**Lock ordering**: `tail` always taken before `slot`. `recv_ref` violates this would-be invariant by initially locking `slot` first, but it drops `slot` (`:1240`) before locking `tail` (`:1244`), avoiding inversion. The post-reacquire mismatch recheck at `:1252` handles the race.

**Wake under tail-lock-dropped window** (`:1038-1048`): notify_rx operates on a moved-out `WaitersList`; new waiters land on the live `tail.waiters` and are observed by a future `notify_rx`. **Correct** — closes #5923 (PR #5925).

**Loom tests** (`tokio/src/sync/tests/loom_broadcast.rs`):
1. `broadcast_send` (lines 9-47): two senders × cap-2 channel; one receiver counts to 6 (Ok+Lagged).
2. `broadcast_two` (51-93): two receivers; one sender; uses Arc strong count to detect leaks.
3. `broadcast_wrap` (95-142): cap-2, three sends, two receivers — exercises wraparound.
4. `drop_rx` (144-180): rx-drop concurrent with sends.
5. `drop_multiple_rx_with_overflow` (182-207): cap-1, multi-sender, drop concurrent with drain.

Coverage gap: no test directly stresses the `Recv::Drop` Acquire-load short-circuit racing with `notify_rx`'s Release-store on `queued`. That path was added in PR #6298 with its own loom test in the PR — would be worth confirming present in current tests.

### 3.4 No new bugs found

After deep analysis, all five candidate scenarios in the user's brief are **correctly handled by the current code**. The system is well-engineered; the value of formal modeling here is to **lock in invariants** that have been broken in the past and to verify that adversarial-caller patterns (which prior round did not model) preserve them.

Specifically:
- All synchronization edges are sound under sequential consistency.
- All cross-variable bridges that depend on Acquire/Release are explicitly annotated and verified.
- No unfixed open bugs in GitHub.
- No code path reads from outside its appropriate lock.

The modeling brief's job is therefore to (a) **freeze** these invariants under TLA+, (b) inject the bounded adversaries (caller misuse, memory-order relaxation) that the user's brief specifically calls out, and (c) demonstrate that no interleaving violates the invariants.

---

## Coverage Statistics

- **Phase 1**: 1 file fully read (1,759 LOC); 5 supporting files surveyed (Notify, linked_list, WakeList, loom shims, loom_broadcast tests).
- **Phase 2**: 81 commits enumerated; 14 deep-read; 67 explicitly excluded with reason. 30+ GitHub issues/PRs deeply read; 12 confirmed bugs; 0 open bug-fix-intent issues.
- **Phase 3**: 3 parallel deep-analysis agents covered (1) cancel/drop/close, (2) adversarial caller patterns, (3) memory ordering + slot reuse. Each agent verified against file:line citations.
- **Output**: `modeling-brief.md` (~ deliverable for Spec Generation), `analysis-report.md` (this file).

---

## References

- Modeling brief: `./modeling-brief.md`
- Source: `/home/ubuntu/Specula/case-studies/tokio-broadcast_2/artifact/tokio/tokio/src/sync/broadcast.rs`
- Loom tests: `/home/ubuntu/Specula/case-studies/tokio-broadcast_2/artifact/tokio/tokio/src/sync/tests/loom_broadcast.rs`
- Notify primitive: `/home/ubuntu/Specula/case-studies/tokio-broadcast_2/artifact/tokio/tokio/src/sync/notify.rs`
- Key PRs: tokio-rs/tokio#2135, #2448, #2509, #3434, #4867, #5578, #5925, #6298, #7232, #7629
- Key issues: tokio-rs/tokio#2123, #2425, #2533, #4814, #5429, #5923, #6649, #7350
- RUSTSEC: 2025-0023 (Tokio broadcast clone unsoundness, March 2025)
