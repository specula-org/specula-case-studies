# MC-4 Investigation — REQUEUE returns only the number of woken waiters

Phase 1 evidence record (no verdict here). Source: model-checking with actual
counterexamples. Worktree HEAD: 0c6053709 (campaign pin).

## Step 1: Code audit

### Cited code (pristine HEAD 0c6053709, kernel/core/src/process/posix_thread/futex.rs)

- **futex.rs:345-382 `futex_requeue`** — full body read.
  - **:353-355** same-address shortcut:
    ```rust
    if futex_new_addr == futex_addr {
        return futex_wake(futex_addr, max_nwakes, visibility);
    }
    ```
    Delegates to WAKE with only `max_nwakes`; `max_nrequeues` is dropped
    entirely. The returned value is WAKE's count of woken waiters.
  - **:368** `let nwakes = futex_bucket.remove_and_wake_items(&futex_key, max_nwakes);`
  - **:370-379** movement: cross-bucket `requeue_items_to_another_bucket(..., max_nrequeues)`
    or same-bucket `update_item_keys(..., max_nrequeues)`.
  - **:381** `Ok(nwakes)` — the syscall result counts woken waiters only; the
    number of moved waiters is never added.
- **futex.rs:485-498 `remove_and_wake_items`** returns the wake count.
- **futex.rs:500-534** — both movement helpers return `()`:
  - `update_item_keys` (:500-511) rekeys up to `max_count` matching items,
    reports nothing.
  - `requeue_items_to_another_bucket` (:513-534) extracts and appends up to
    `max_nrequeues` matching items, reports nothing.
  So the caller *cannot* add the moved count to the return value without an
  interface change; the count is lost by design of these helpers.

### Call chain (public API reachability)

`sys_futex` (kernel/core/src/syscall/futex.rs:22) → `FutexOp::FUTEX_REQUEUE`
arm (syscall/futex.rs:105-118): `max_nwakes = futex_val_to_max_count(futex_val)`
(`futex_val_to_max_count` = `(val as i32).max(1)`, syscall/futex.rs:146-151 —
identity for val ≥ 1), `max_nrequeues = (utime_addr as i32).max(0)`, then
`futex_requeue(futex_addr, max_nwakes, max_nrequeues, futex_new_addr, ...)`.
The syscall result is returned to userspace verbatim
(syscall/futex.rs:143-144 `Ok(SyscallReturn::Return(res as _))`).

**Reachability**: any userspace program calling
`syscall(SYS_futex, uaddr, FUTEX_REQUEUE|FUTEX_PRIVATE_FLAG, nw, nm, uaddr2, 0)`
traverses the whole chain. No precondition beyond "waiters exist on uaddr".
Fully reachable in normal usage; no timing requirement at all — the return
value is a deterministic function of the syscall's arguments and the queue
state.

### Linux reference (pinned v6.16.5, local checkout
.../parallel-scopes-2026-10-04/linux-v6.16.5)

- `kernel/futex/syscalls.c:109-110`: `FUTEX_REQUEUE → futex_requeue(uaddr, flags,
  uaddr2, flags, val, val2, NULL, 0)` — ordinary REQUEUE, `cmpval=NULL`,
  `requeue_pi=0`. No same-address shortcut in the dispatcher.
- `kernel/futex/requeue.c:584-610` (the requeue loop):
  ```c
  plist_for_each_entry_safe(this, next, &hb1->chain, list) {
      if (task_count - nr_wake >= nr_requeue)
          break;
      ...
      /* Plain futexes just wake or requeue and are done */
      if (!requeue_pi) {
          if (++task_count <= nr_wake)
              this->wake(&wake_q, this);
          else
              requeue_futex(this, hb1, hb2, &key2);
          continue;
      }
  ```
  `task_count` is incremented for **each** matching waiter, whether woken
  (`++task_count <= nr_wake`) or moved (`requeue_futex`).
- `kernel/futex/requeue.c:691`: `return ret ? ret : task_count;` — the syscall
  returns woken **plus** requeued.
- Same-address case: `requeue_pi` is 0, so the `uaddr1 == uaddr2 → -EINVAL`
  check (requeue.c:404, requeue_pi-only) does not apply. With identical keys
  hb1 == hb2 (single lock via double_lock_hb), and `requeue_futex`
  (requeue.c:76-103) is a **no-op move** when `hb1->chain == hb2->chain`
  (only `q->key = *key2`), but the waiter still goes through `++task_count`
  in the loop — so it is **counted** even though nothing physically moves.
- Contracts pin (contracts.md L1): "Ordinary REQUEUE passes `cmpval=NULL` and
  `requeue_pi=0`. Its count includes both woken and moved waiters."

### Manual-page conflict (recorded, not resolved by us)

contracts.md: "The current REQUEUE manual (man-pages 6.19, inspected 2026-10-04)
describes only a wake count. That conflicts with L1... Use the fixed
implementation as the versioned reference and obtain a Linux control before
claiming compatibility failure." The CMP_REQUEUE manual describes the combined
count. The campaign's calibration rule is therefore: Linux implementation
(v6.16.5 pinned source + running-kernel control) is the reference, not the
FUTEX_REQUEUE(2const) page.

### Counterexamples (spec/output/hunt-round2/)

- `MC_hunt_s2_return_count-bfs.out` (30 states, config MC_hunt_s2_return_count.cfg):
  `MCWait(1,"A",0)`, `MCWait(2,"A",0)`, then
  `MCCall(1,p,"requeue","A","B",1,1)` (State 14). Final state (State 30):
  op kind="requeue", pc="done", wakes=1, processed=1, result=1. Invariant
  `RequeueReturnCount` (base.tla:560-561: result = wakes + processed for done
  requeues) requires result=2. Violated.
- `MC_hunt_s2_same_address-bfs.out` (24 states, config MC_hunt_s2_same_address.cfg):
  same shape but `MCCall(1,p,"requeue","A","A",1,1)` (State 14). Final state:
  wakes=1, processed=1, result=1, expected 2. Same violation.

Both CEs instantiate directly as: two threads blocked on FUTEX_WAIT at A,
then `REQUEUE(A→B, 1, 1)` (resp. `REQUEUE(A→A, 1, 1)`). One waiter is woken,
one is moved (resp. counted as a same-key requeue), the syscall returns 1;
Linux returns 2.

### Trigger scenario (concrete)

1. Threads W1, W2 call `FUTEX_WAIT(A, 0)` (private) and block — both enrolled
   in A's bucket.
2. Main thread calls `FUTEX_REQUEUE(A→B, 1, 1)` (private; A≠B, both aligned
   u32 words in the same stable address space).
3. Asterinas: wakes W1 (nwakes=1), moves W2 to B (max_nrequeues=1), returns
   `Ok(1)`. Linux: wakes W1, requeues W2, returns 2.
4. Same-address variant: `FUTEX_REQUEUE(A→A, 1, 1)`. Asterinas takes the
   :353-355 shortcut → `futex_wake(A, 1)` wakes W1, returns 1; `max_nrequeues`
   ignored. Linux counts W1 (woken) + W2 (no-op same-key requeue) → 2.

Caller-side safeguards: none. No caller between the syscall layer and
userspace transforms the return value; no downstream mechanism corrects it.

### Consequence (who reads the value)

The syscall return value is the ABI-visible result. Real consumers:
- glibc/musl `pthread_cond_broadcast`-family paths built on FUTEX_REQUEUE use
  the return count to decide whether all waiters were already woken (vs.
  needing more work). PR 2515's body documents that LTP's `tst_checkpoint`
  family treats futex return values as load-bearing
  (asterinas/ltp lib/tst_checkpoint.c). Any caller that loops "while requeue
  returns < expected" or compares the count against its own waiter census
  observes a wrong outcome. The wrong value is permanent — it is consumed at
  syscall return; no later kernel action fixes it.

## Step 2: Developer-knowledge search

- **git blame** (futex.rs at HEAD): `Ok(nwakes)` (line 381) and the
  same-address shortcut (lines 353, 355) both originate in commit 1e89933a99
  "implement posix thread" (Jianfeng Jiang, 2022-12-20) — the original futex
  implementation. Line 354's `visibility` argument was added by 55ad5d91f
  (Qingsong Chen, 2026-03-27, "Fix futex wake matching across address
  spaces"). No commit message or comment states any intent about the REQUEUE
  return count; nothing suggests a deliberate deviation.
- **Comments near the code**: none mention the return count. The syscall-layer
  comment (syscall/futex.rs:107-108) only documents `utime_addr` reuse for the
  requeue quota.
- **Tests**: no upstream test in the tree asserts REQUEUE return values. The
  only C code exercising FUTEX_REQUEUE is the campaign's own untracked harness
  (`test/initramfs/src/regression/process/specula_futex/scenarios.c` —
  `git status` shows it untracked, added by the campaign). Upstream regression
  dirs under `test/initramfs/src/regression/process/` contain no futex
  requeue test.
- **Book** (`book/src/kernel/linux-compatibility/syscall-flag-coverage/
  inter-process-communication/futex.scml`): documents the REQUEUE operation
  signature but says nothing about the return value — no documented claim
  that wake-only semantics are intended.
- **Issue tracker / PRs** (searched via gh, 2026-10-10):
  - Issues matching "futex" (40 reviewed): #3964 (open) covers *different*
    mechanisms — waiters requeued to a different hash bucket missed by
    cleanup, plus the `futex_val_to_max_count` normalization applied to the
    REQUEUE *wake quota* ("As with the FUTEX_WAKE arm, the FUTEX_REQUEUE arm
    normalizes the number of waiters to wake... I don't think this
    normalization should be applied"). It does **not** mention the return
    count. #35 (old "Known limitations"): atomicity + key selection, different
    aspects. #2393, #981, #1641, #2188, #2805, #1587, #1381, #1179, #1334:
    all different mechanisms.
  - Omnibus #3920 "Soundness bugs uncovered during agentic scan": unsafe-rust
    soundness in OSTD, not syscall semantics; no requeue mention.
  - PRs matching "futex" (30 reviewed): 2515 "Fix or clarify some futexes
    bugs" — shared-mapping keys + FUTEX **WAIT** return-value correctness for
    LTP `tst_checkpoint_wait` (different site and mechanism; its body does
    show the project treats futex return values as LTP-load-bearing).
    2815 "Improve futex code and log clarity" — cosmetic (indentation at
    `futex_requeue`). 2404 locking refactor, 2424 book SCML, 3331 ENOSYS for
    unsupported ops, 2146 WAKE_OP, 2190 overflow, 2377/2405/2409 wake-reason
    detection, 2343 robust futexes, 2339 FutexKey usage, 2306 fallible
    atomics — none touch the REQUEUE return count.
  - Searches "requeue return", "return value futex": no hits beyond the above.

## Step 3: Known-status / precedent

No existing issue, PR, CVE, or advisory reports the REQUEUE return-count
divergence (wakes-only vs wakes+moved) at `futex_requeue` / the same-address
shortcut. The nearest report (#3964) is a different mechanism at an adjacent
site (quota normalization + cleanup bucket). Searched open and closed issues
and merged/closed PRs including recent ones. **Novelty: NEW** (recorded for
the report; not a drop — source is MC with an actual counterexample, so
Phase 2 proceeds regardless).

## Notes for Phase 2

- The divergence is deterministic: single syscall, no race, no bucket-layout
  dependence (distinct-address shape) — Level 0 black-box should trigger it
  directly. The only timing requirement is that both waiters be enrolled
  before the REQUEUE; the test must prove enrollment via the post-hoc wake
  signature (WAKE(B) must return 1 and WAKE(A) 0 after REQUEUE(A→B,1,1),
  and both waiters must exit WAIT with 0 rather than ETIMEDOUT), and via the
  campaign kernel's SPECULA enrollment probe (op 0x5350, cmd 5) where
  available.
- Reused campaign kernel binary: harness/build/target/osdk/iso_root/boot/
  asterinas-osdk-bin (source 0c6053709, sha256 39ae3549..., the binary used
  for all 18 campaign trace cases). Its futex instrumentation is
  observation-only (probe::mark/tr::stamp added around existing operations;
  the `Ok(nwakes)` return and both movement helpers are unchanged — verified
  by reading the worktree diff of `futex_requeue`). Same reuse rationale as
  the MC-3 confirmation, which booted this binary successfully.
- Linux control: same C binary natively on the host (Linux 7.2.8), where
  REQUEUE must return 2 in both shapes.
