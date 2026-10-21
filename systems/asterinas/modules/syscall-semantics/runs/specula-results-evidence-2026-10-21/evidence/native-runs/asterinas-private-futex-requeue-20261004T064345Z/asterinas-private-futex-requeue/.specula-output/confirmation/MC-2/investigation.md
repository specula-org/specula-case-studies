# MC-2 Investigation (Phase 1 — evidence only)

Finding: "Ordinary REQUEUE with a zero wake quota wakes a waiter"
Source: model-checking, Scenario 2, contract case F05 (TV-1). Counterexample:
`spec/output/hunt-round2/MC_hunt_s2_zero_wake-bfs.out` (invariant `RequeueWakeQuota`).

## Step 1: Code audit

### Cited code (worktree = campaign source 0c6053709 + instrumentation)

`kernel/core/src/syscall/futex.rs` — `sys_futex`, FUTEX_REQUEUE arm:

```rust
FutexOp::FUTEX_REQUEUE => {
    let max_nwakes = futex_val_to_max_count(futex_val);
    // `utime_addr` is used as the maximum number of requeues in this case.
    // When `utime_addr` is 0 or negative, it means no requeues.
    let max_nrequeues = (utime_addr as i32).max(0) as usize;
    futex_requeue(futex_addr as _, max_nwakes, max_nrequeues, futex_new_addr as _, ctx, visibility)
}
```

`kernel/core/src/syscall/futex.rs` (end of file):

```rust
fn futex_val_to_max_count(futex_val: u32) -> usize {
    // Linux wakes one waiter even if `futex_val` is 0 or negative. To be
    // consistent with Linux, we set `max_count` to 1 if it is 0 or negative.
    // Reference: <https://elixir.bootlin.com/linux/v7.2/source/kernel/futex/waitwake.c#L219>
    (futex_val as i32).max(1) as usize
}
```

`kernel/core/src/process/posix_thread/futex.rs:455` — `futex_requeue`:

```rust
let nwakes = futex_bucket.remove_and_wake_items(&futex_key, max_nwakes);
...
Ok(nwakes)
```

`kernel/core/src/process/posix_thread/futex.rs:682` — `remove_and_wake_items`:

```rust
self.items.retain(|item| {
    let attempted = item.key.match_up(key) && count < max_count;
    ...
});
```

### Call chain and reachability

`sys_futex` (public syscall entry, `kernel/core/src/syscall/futex.rs:23`) →
`FutexOp::FUTEX_REQUEUE` arm → `futex_val_to_max_count(0)` → `1` →
`futex_requeue(addr_a, 1, 0, addr_b, ...)` → `remove_and_wake_items(key_a, 1)`
→ first matching waiter is woken (`item.wake()`), removed from the bucket, and
`Ok(1)` is returned to userspace.

The path is reached by any userspace `syscall(SYS_futex, uaddr, FUTEX_REQUEUE
[|FUTEX_PRIVATE_FLAG], 0, 0, uaddr2, 0)` — a plain public syscall with
nonnegative quotas, no fault injection, no unusual state. Reachability is
unconditional: the conversion happens before any bucket lookup.

### Linux reference (verified from source)

- `kernel/futex/waitwake.c` `futex_wake()`: `this->wake(&wake_q, this); if
  (++ret >= nr_wake) break;` — the wake happens BEFORE the quota test, so
  FUTEX_WAKE with val=0 still wakes one waiter. This is the quirk
  `futex_val_to_max_count` cites, and it is WAKE-only.
- `kernel/futex/requeue.c` `futex_requeue()`: the loop head tests
  `if (task_count - nr_wake >= nr_requeue) break;` and the wake branch is
  `if (++task_count <= nr_wake) this->wake(...); else requeue_futex(...)` —
  the quota is tested BEFORE waking. With nr_wake=0, nr_requeue=0: the loop
  breaks immediately (0-0 >= 0), wakes nobody, requeues nobody, returns 0.

So Linux REQUEUE(0,0) returns 0 and leaves every waiter blocked on the source
key; Asterinas returns 1 and wakes one waiter.

### MC counterexample (admissible trace)

`MC_hunt_s2_zero_wake-bfs.out`: State 2/3 `MCWait(1,"A",0,...)` and
`MCWait(2,"A",0,...)` enroll two waiters on key A; State 14
`MCCall(1,p,"requeue","A","B",0,0)` issues REQUEUE(A→B, 0, 0); the invariant
`RequeueWakeQuota == \A c : s.op[c].kind="requeue" => s.op[c].wakes <=
s.op[c].rawWake` is violated because the model's `effective=Max(1,nw)` (the
faithful image of `futex_val_to_max_count`) lets `wakes=1 > rawWake=0`.

Implementation trace `traces/case-16.ndjson` (campaign harness, SMP 2, source
0c6053709): `SysFutexControl {kind: requeue, src: A, dst: B, nw: 0, nm: 0}` →
`FutexItemWake {g: 2001, attempted: true, accepted: true}` →
`FutexWakeRetain {wakes: 1}` → `FutexRequeueFinish {wakes: 1, moves: 0}` →
`SysFutexControlReturn {result: 1}`. The kernel woke one of two enrolled
waiters and returned 1 for REQUEUE(0,0).

### Trigger scenario (concrete, natural)

1. Two threads call `FUTEX_WAIT` on private futex word A (value 0, expected 0,
   no timeout) and block; a third thread observes both enrolled.
2. The third thread calls `futex(A, FUTEX_REQUEUE|FUTEX_PRIVATE_FLAG,
   nr_wake=0, nr_requeue=0, &B)`.
3. Linux: returns 0; both waiters stay blocked on A. Asterinas: returns 1;
   one waiter's FUTEX_WAIT returns 0 ("woken") although the futex word never
   changed and the caller requested zero wakes.

### Safeguards encountered

None on this path. The conversion is unconditional in the syscall arm; no
later kernel mechanism un-wakes the waiter or corrects the return value. The
waiter's own cleanup (`futex_wait_bitset` epilogue) treats "item already
removed" as success, so the spurious wake is reported to userspace as a
successful FUTEX_WAIT return. (A separate known issue, #3964's main subject,
concerns cleanup after cross-bucket requeue — different mechanism, not a mask
for this one.)

## Step 2: Developer-knowledge search

- Commit `860bb6c07` "Adjust and correct parts of the futex implementation
  code" (2025-06-16) introduced the defect: before it, the REQUEUE arm used
  `get_futex_val(futex_val as i32)?` — the RAW value (EINVAL on negative);
  the commit factored the WAKE-only quirk into `futex_val_to_max_count` and
  applied it to REQUEUE as well. The pre-existing comment cited
  gVisor/test/syscalls/linux/futex.cc:260 ("The Linux kernel wakes one waiter
  even if val is 0 or negative") — a statement about FUTEX_WAKE. The commit
  message gives no rationale for changing REQUEUE's quota semantics; it looks
  like an over-generalizing refactor, not a deliberate decision.
- Current comment (commit `663175339`) cites
  elixir v7.2 waitwake.c#L219 — again the WAKE quirk only.
- No test in the tree asserts REQUEUE(0, ...) behavior: `grep -rn "FUTEX_REQUEUE"
  test/` matches only the campaign's own `specula_futex/scenarios.c` (case 16
  exercises REQUEUE(0,0) but asserts nothing about the result). No upstream
  LTP-style return-count assertion exists for REQUEUE.

## Step 3: Known-status / precedent

- Upstream issue **asterinas/asterinas#3964** "Futex wait can miss waiters
  requeued to a different hash bucket" (opened 2026-10-06 by bdm-k, state
  OPEN, label C-bug) contains, verbatim: "There is also an issue with
  `sys_futex()`. As with the `FUTEX_WAKE` arm, the `FUTEX_REQUEUE` arm
  normalizes the number of waiters to wake using `futex_val_to_max_count()`.
  However, I don't think this normalization should be applied to
  `FUTEX_REQUEUE` to match Linux."
  → SAME mechanism at SAME site, already reported. Maintainer (tatetian)
  replied "The reported finding sounds reasonable... we'd love to accept a
  fix" (2026-10-07). No fix PR exists (0 open PRs match; merged PRs
  #2815/#2424/#2404/#1577 predate or do not touch this).
- Novelty: **KNOWN (cite: https://github.com/asterinas/asterinas/issues/3964;
  fix-status: unfixed)**.
- This finding is MC-sourced with an actual counterexample, so per the skill
  it proceeds to Phase 2 regardless of KNOWN status; the code-review × known
  drop does not apply.

## Reproduction plan (Phase 2)

- Level 0 (pure black box): a portable C program enrolls two waiters on a
  private futex word A, then calls REQUEUE(A→B, 0, 0) and observes (a) the
  syscall return value and (b) how many waiters' FUTEX_WAIT returned during a
  300 ms window before any cleanup wake. Enrollment is gated on the
  instrumented kernel's SPECULA probe (futex op 0x5350, command 5 = enrolled
  count) when available, with a timed-spin fallback for uninstrumented
  kernels — the probe is used only to observe enrollment, never to create the
  bug.
- Control: the same binary runs natively on the host Linux 7.2.8 kernel,
  which must show the Linux-correct result (return 0, no wake).
- Bug run: the same binary is compiled static in the campaign dev container,
  installed as the guest `/init` on an initramfs paired with the already
  built campaign kernel image (harness `build/target/osdk/iso_root/boot/
  asterinas-osdk-bin`, source 0c6053709 — no source changes, kernel reused),
  packaged with grub-mkrescue, and booted under QEMU (KVM, SMP 2, 2G) per the
  harness recipe. Container limits per resources.json: cpus 2, memory 8g,
  pids 512. heavy.lock is held by the receiving controller; not reacquired.
