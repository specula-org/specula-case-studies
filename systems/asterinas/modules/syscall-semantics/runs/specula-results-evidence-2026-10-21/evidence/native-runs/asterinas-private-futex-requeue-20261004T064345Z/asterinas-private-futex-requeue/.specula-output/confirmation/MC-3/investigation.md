# MC-3 investigation — same-bucket REQUEUE with zero migration quota moves one waiter

Phase 1 record (evidence only). Worktree: `confirmation/MC-3/worktree`
(Asterinas @ `0c60537098f4c2949ad2d382aaf499de72263d76` + campaign
observation-only instrumentation; the futex logic is upstream-identical,
verified by diffing `git show HEAD:...futex.rs` against the worktree file —
all non-probe/trace hunks are cosmetic).

## Step 1: Code audit

### Cited code (upstream, `git show HEAD:kernel/core/src/process/posix_thread/futex.rs`)

Same-bucket path — `FutexBucket::update_item_keys` (upstream lines 500–511):

```rust
pub(self) fn update_item_keys(&mut self, key: &FutexKey, new_key: &FutexKey, max_count: usize) {
    let mut count = 0;
    for item in self.items.iter_mut() {
        if item.key.match_up(key) {
            item.key = new_key.clone();   // rekey (move) happens FIRST
            count += 1;
        }
        if count >= max_count {           // quota tested AFTER the move
            break;
        }
    }
}
```

With `max_count == 0`, the first remaining item whose key matches the source
key is rekeyed to the destination key, then `count (1) >= 0` breaks the loop:
exactly one waiter is migrated despite a zero migration quota.

Cross-bucket path — `FutexBucket::requeue_items_to_another_bucket` (upstream
lines 519–535) tests the quota BEFORE moving:

```rust
if item.key.match_up(key) && count < max_nrequeues {   // quota gate first
    count += 1;
    true
} else { false }
```

So the two paths disagree at `max_nrequeues == 0`: cross-bucket moves nothing,
same-bucket moves one.

Dispatch — `futex_requeue` (upstream lines 345–382; the `else` arm at line 378):

```rust
if futex_new_addr == futex_addr { return futex_wake(...); }
...
let (mut futex_bucket, futex_new_bucket) = lock_bucket_pairs(&futex_key, &futex_new_key);
let nwakes = futex_bucket.remove_and_wake_items(&futex_key, max_nwakes);
if let Some(mut futex_new_bucket) = futex_new_bucket {
    futex_bucket.requeue_items_to_another_bucket(...);   // different buckets
} else {
    futex_bucket.update_item_keys(&futex_key, &futex_new_key, max_nrequeues);  // line 378
}
```

`lock_bucket_pairs` returns `None` for the second guard iff both keys hash to
the same bucket index (`futex.rs:637`: `index = key.hash & (self.size() - 1)`).
Private keys hash via `jhash_3vals(addr_lo, addr_hi, vmar_mix, 0)`
(`futex.rs:903-911`); bucket count is `((1<<8) * num_cpus()).next_power_of_two()`
(512 for the campaign's SMP=2 guest). Two distinct aligned addresses in one
address space collide with probability ~1/512 per pair — the harness's case-05
guest found 3 colliding words among a 4096-word array (manifest:
`traces/case-05.ndjson`, `bucket_of {A:6, B:6, C:6}`, `bucket_count: 512`).

### Call chain / reachability

`sys_futex` (`kernel/core/src/syscall/futex.rs:236-248`, FUTEX_REQUEUE arm,
fully public syscall) → `futex_requeue` → same-bucket arm →
`update_item_keys`. The move quota comes from the 4th syscall argument:
`let max_nrequeues = (utime_addr as i32).max(0) as usize;` — no 0→1
normalization is applied to the MOVE quota (only the wake quota goes through
`futex_val_to_max_count`, which is MC-2's separate bug). So a user
`futex(A, FUTEX_REQUEUE_PRIVATE, 1, 0, C, 0)` reaches `update_item_keys`
with `max_count == 0` whenever A and C share a bucket. Reachable through
normal usage; no fault, no privileged state.

### Trigger scenario (matches the MC counterexample)

1. Two threads FUTEX_WAIT_PRIVATE on word A (value 0, expected 0) — CE states
   2 and 6 (`MCWait(1,"A",0)`, `MCWait(2,"A",0)`).
2. A controller thread issues `FUTEX_REQUEUE_PRIVATE(A, nw=1, nm=0, C)` with
   A and C in the same bucket — CE state 14
   (`MCCall(1,p,"requeue","A","C",1,0)`).
3. Asterinas wakes one waiter and rekeys the other to C (CE final op state:
   `wakes=1, moves=1`, violating `RequeueMoveQuota == moves <= rawMove`,
   base.tla:559).
4. A later `FUTEX_WAKE_PRIVATE(A, 2)` returns 0 — the migrated waiter is no
   longer reachable via the source key; only `FUTEX_WAKE(C, ...)` reaches it.

### Reference behavior (Linux 7.2.8)

`kernel/futex/requeue.c:600` (verified against the local NixOS 7.2.8 source
tree, sha256-matched to `analysis-evidence/linux-reference-integrity.json`):

```c
plist_for_each_entry_safe(this, next, &hb1->chain, list) {
        if (task_count - nr_wake >= nr_requeue)   /* quota tested BEFORE each waiter */
                break;
        if (!futex_match(&this->key, &key1))
                continue;
        ...
        if (++task_count <= nr_wake)
                this->wake(&wake_q, this);
        else
                requeue_futex(this, hb1, hb2, &key2);
```

With `nr_requeue == 0` no waiter is ever requeued, regardless of bucket
sharing. The campaign's Linux 7.2.8 control run confirms this behaviorally
(`harness/logs/linux-control.ndjson`): REQUEUE(1,0) → `result 1,
destination_wakes 0, source_wakes 1` (the second waiter stayed on the source
word); REQUEUE(0,0) → `result 0, source_wakes 2`.

### Implementation-trace precedent

`traces/case-05.ndjson` (real syscalls on the campaign kernel, SMP=2 KVM
guest): REQUEUE(A→B, nw=1, nm=0) with A, B same bucket 6 →
`FutexUpdateItemKey {g:3001, moves:1, entryKey:"B"}` — the second waiter was
rekeyed to B despite nm=0; subsequent WAKE(B,2) woke it (returns 1) and
WAKE(A,2) returned 0. This is the same mechanism, captured by the harness
before the finding was filed.

### Safeguards encountered

None on this path: `update_item_keys` has no quota pre-check; the syscall
layer's only guard is the `futex_new_addr == futex_addr` early-out (which
turns same-address requeue into a plain wake — different situation). The
migrated waiter remains a live, wakeable waiter (only under the wrong key),
so no downstream mechanism repairs the key; the harm persists until the
caller happens to wake the destination word or the waiter times out.

## Step 2: Developer knowledge

- `git log -S "update_item_keys"`: introduced with the original futex
  implementation (`895e5c340 "add syscall futex"`, 2022-09-29); the
  move-then-check ordering survived the 2024 rewrite
  (`cd9e5d11d "Optimize futex implementation"`, which introduced the current
  `count >= max_count` break AFTER the rekey). No commit message mentions
  quota semantics for this function.
- Syscall-layer comment (`kernel/core/src/syscall/futex.rs:238-239`):
  "`utime_addr` is used as the maximum number of requeues in this case.
  When `utime_addr` is 0 or negative, it means **no requeues**." — the
  caller-side contract explicitly states a zero quota means zero moves;
  `update_item_keys` contradicts it.
- Book (`book/src/kernel/linux-compatibility/syscall-flag-coverage/
  inter-process-communication/futex.scml:32-33`): "requeue up to
  `max_requeue_waiters` of the remaining waiters" — up to 0 means none.
- No TODO/FIXME near `update_item_keys`. No upstream test exercises
  FUTEX_REQUEUE with a zero move quota (the only futex tests in-tree are the
  campaign's own `specula_futex` harness; `test/initramfs` has no other
  requeue test).

## Step 3: Known status / precedent

Tracker searches performed (2026-10-09):
- GitHub `asterinas/asterinas` issues+PRs matching "requeue" (7 results,
  inspected individually): #3985 (nvme), #3964 (open issue: cross-bucket
  requeue + timeout cleanup searches the ORIGINAL bucket — a different
  mechanism: resource leak after cross-bucket move; also flags
  `futex_val_to_max_count` on the REQUEUE wake count — MC-2's mechanism,
  not the same-bucket zero-MOVE-quota rekey), #2984 (ptrace), #2815 (log
  clarity), #2424 (book), #2404 (double-bucket locking), #1577 (EINTR
  revert).
- PRs matching "futex" updated since 2026-09-01: #3619 (benchmark),
  #3576 (syscall restart), #2409 (awakening-reason detection, closed
  unmerged draft) — none touch `update_item_keys` or quota ordering.
- Commit history: no fix commit touches the quota ordering in
  `update_item_keys` (only the 2022 introduction and the 2024 rewrite).
- Web searches (exa) for the mechanism: surface #1587, #1641, PR #2515,
  commits 91351e3/c31c611/52ddbea/43f50c5 — all different mechanisms
  (lost-wakeup on pause_timeout, bucket hash distribution, shared-mapping
  key identity, return values).

No existing report describes a zero-migration-quota same-bucket REQUEUE
moving a waiter. **Novelty: NEW.** (MC-sourced with an actual
counterexample, so no Phase-1 drop applies; proceed to Phase 2.)
