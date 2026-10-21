# MC-1

Status: REPRODUCED
Run: asterinas-private-futex-requeue-20261004T064345Z

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Let me inspect the current workspace to verify which deliverables from the previous session are intact:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && ls -la confir...
My MC-1 deliverables are intact. There are new files in my finding's work dir (`debate.md`, `error.txt`) created right after my previous turn, plus sibling workers' artifacts (MC-2, MC-3, CR-1) in the shared repro dir. Let me read the debate and error files to understand what happened before this work was accepted:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
The previous turn's verdict was recorded (`VERDICT: REPRODUCED`), but the dispatcher's artifact validation failed: my `issue.json` links model actions/invariants but contains no **model dependencies** (`root: "work"` entries). That's the remaining deliverable. Let me read the validator to fix the proposal precisely:
running sed -n '350,470p' /home/chin39/Documents/play/Specula/src/specula/persistent_findings.py
running grep -n "_dependency_bytes\|def _bytes\|def _path" /home/chin39/Documents/play/Specula/src/specula/persistent_findings.py | head; sed -n "$(grep -n 'def _dep...
Two problems to fix in `issue.json`: (1) missing model dependencies (`root: "work"`) required because actions/invariants are linked, and (2) my source span boundaries contain embedded newlines (`"    result\n}"`) — the validator requires **single-line** boundaries, so those would fail next. Let me fix both and then run the validator myself:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && python3 - <<'...
running /home/chin39/Documents/play/Specula/.venv/bin/specula findings --work /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T06434...
Validation passes. Let me check the rest of `_validate_final_artifacts` so nothing else fails at acceptance:
running sed -n '1300,1380p' /home/chin39/Documents/play/Specula/src/specula/confirmlib.py
The proposal now validates (`"valid": true`) and all other final-artifact gates pass: REPRODUCED for an MC-sourced finding, non-empty `repro/test_bugMC-1_*` artifacts present, record ID matches. Let me do a final integrity sweep of all deliverables:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && ls -la repro/...
All deliverables are complete and the blocking validation failure is fixed. Re-emitting the final confirmation result:

# MC-1 Confirmation Result

- **Source**: MC
- **Novelty**: NEW — searched the upstream tracker (open and recently merged/closed items through 2026-10) and git history. Closest prior art is asterinas issue #1587 (closed 2024-11, fixed by 888eecb35/PR #1642), which reported the **total absence** of cleanup on timeout/signal; it never mentions REQUEUE or cross-bucket movement. MC-1 is a residual defect of that fix (removal executed against the wrong bucket after a cross-bucket requeue) plus the 0-vs-ETIMEDOUT return corruption and dead-entry quota consumption — none of which any existing report covers.
- **Location**: `kernel/core/src/process/posix_thread/futex.rs:79` and `futex.rs:121-130` (primary); `futex.rs:485-498`, `futex.rs:500-511`, `futex.rs:513-534`; `ostd/src/sync/wait.rs:244-250`, `wait.rs:262-265`

## Description

`futex_wait_bitset` saves the bucket reference of the **original** key (futex.rs:79) and, after `pause_timeout`, removes its `FutexItem` only from that bucket (futex.rs:121-130). A cross-bucket `FUTEX_REQUEUE` moves the item into another bucket via `requeue_items_to_another_bucket` (futex.rs:513-534). A waiter that times out after being moved therefore misses the lookup: the syscall returns `Ok(())` — success — instead of `ETIMEDOUT`, and the item is never dequeued. Once the `Waiter` drops and closes the waker (wait.rs:262-265), the dead entry is permanent: `WAKE` retains it because `wake_up()` returns false for a closed waker (futex.rs:485-498, wait.rs:244-250), and both migration paths still count it against their quota (futex.rs:500-534). The developer's own comment states the violated obligation: the item "must be dequeued and dropped. Otherwise, malicious user programs could repeatedly issue futex wait operations to exhaust kernel memory."

## Trigger scenario

Words A and B in different futex buckets. W1: `FUTEX_WAIT(A)` untimed. W2: `FUTEX_WAIT(A, 300ms)`, enqueued after W1. `REQUEUE(A→B, 1 wake, 1 move)` wakes W1 and moves the still-sleeping W2 into B's bucket. W2's timer fires; its cleanup locks the original bucket A, `remove_by_waker` misses, and it returns 0 instead of `-ETIMEDOUT`; its closed item stays in B's bucket. Then W3 and W4 wait untimed on B; `REQUEUE(B→A, 1, 1)` wakes W3 but its move quota is consumed by the dead entry, leaving live W4 blocked on B; `WAKE(A, 1)` returns 0 and wakes nobody. This instantiates CE `MC_hunt_s3_owner` (states 25-55, ResourceAccountingBalance) and CE `MC_hunt_s4_live_migration` (LiveMigrationExhaustion); the campaign's real-kernel traces case-11/case-13 show the same histories.

## Developer intent

Commit `bc5a058fc` (2024-12) added a TODO for the undequeued-item vulnerability → issue #1587 → fixed by `888eecb35` (2025-08) with removal **from the saved original bucket**. Commit `43f50c5e2` (2025-10, PR #2515, merged 2025-10-20) switched to `remove_by_waker` and introduced `item.is_none() → Ok(())` on the stated assumption "the futex item will be removed asynchronously **if and only if** it has been woken up" — cross-bucket REQUEUE breaks that assumption. No existing test asserts the requeue+timeout interaction. Linux dequeues a completed waiter by following `q->lock_ptr` (kernel/futex/core.c `futex_unqueue`), so a completed waiter never stays queued there.

## Reproduction result

Test: `repro/test_bugMC-1_requeue_timeout_strand.c` + runner `repro/test_bugMC-1_requeue_timeout_strand.sh` (Level 0, pure black-box syscalls; kernel image reused unchanged from the campaign harness; observation-only probe used solely for cross-bucket address selection and enrollment gating; native Linux run of the identical binary as control). **PASS — bug triggered in 3/3 guest boots**, deterministic.

Guest (Asterinas, SMP=2 KVM, real output from `repro/run-output.log`):
```
MC1_OBS attempt=0 bucket_a=502 bucket_b=72 cross_bucket=1
MC1_OBS attempt=0 rq1=1 w1=(0,0) w2=(0,0) rq2=1 wake_a=0 w4_done_before_wake_b=0 wake_b=1 w3=(0,0) w4=(0,0)
MC1_LINUX_EXPECT w2=(-1,ETIMEDOUT=110) wake_a=1 w4_done_before_wake_b=1
MC1_BUG1_REPRODUCED attempt=0 timed-out requeued waiter returned 0 instead of -ETIMEDOUT
MC1_BUG2_REPRODUCED attempt=0 dead entry consumed requeue(B->A,1,1) move quota: wake(A,1)=0 and live W4 left blocked on B
MC1_VERDICT REPRODUCED
```
Control (same binary, native Linux): `w2=(-1,110)` (correct ETIMEDOUT after being requeued), `wake_a=1`, W4 woken from A. Kernel-side trace decoded from the guest dump matches the counterexample step-for-step: W2 registered in bucket 186, timer fired, `FutexCleanupLock` locked the **original** bucket 186, `FutexRemoveByWaker` returned item_present=0 (miss — the item was in bucket 87), `FutexWaitDecide` code=0 (Ok), `WaiterDrop`. Root cause, sequence, and violated properties (ResourceAccountingBalance, LiveMigrationExhaustion) all match the MC finding.

## Recommendation

Give the `FutexItem` an owner that follows the item, mirroring Linux's `q->lock_ptr`: `requeue_items_to_another_bucket` should record the destination bucket in the item under the pair lock, and the timeout/signal cleanup should lock and remove from the item's **current** bucket instead of the saved original one (the correct ETIMEDOUT return then falls out naturally since the item is found). Defensively, `remove_and_wake_items` and both requeue paths should skip-and-drop entries whose waker is already closed rather than retaining and re-migrating them, so any future stranding cannot absorb wake scans or migration quotas.

### Pre-REPRODUCED checklist

1. **Level 0 alone? Yes.** Real public futex syscalls from ordinary pthreads in a real SMP=2 KVM Asterinas guest; no failpoints, no state injection, no source modification. The only assistance was read-only observation queries (bucket identity, enrollment count) used to sequence thread starts — timing/setup help only, replaceable by delays.
2. **N/A** — no Level 2 or Level 3 was needed.
3. **Real consumers**: (a) the timed-out waiter's own thread observes the wrong syscall result — 0 instead of -ETIMEDOUT (recorded in `test_bugMC-1_requeue_timeout_strand.c:66`, output `w2=(0,0)`); (b) the `FUTEX_WAKE(A,1)` caller observes return 0 instead of 1 with nobody woken; (c) the live W4 thread is left blocked on the wrong futex until the test's explicit `WAKE(B,1)`. All three observed, none argued-only.
4. **Permanent.** The stranded closed item is never removed by any kernel mechanism (WAKE retains closed items at futex.rs:485-498; nothing sweeps buckets) — demonstrated live by the dead entry surviving to consume a later REQUEUE's quota. W4's blockage was resolved only by the test's own user-space wake, not a kernel safeguard. The per-item memory retention (`Arc<Waker>` → `Arc<Task>` → exited thread's kernel stack) remains code-inferred, not measured, as the finding itself noted.

Artifacts: `confirmation/MC-1/investigation.md` (Phase 1 + Phase 2 record), `confirmation/MC-1/issue.json` (persistent-finding proposal, now validated: `{"id": "MC-1", "status": "REPRODUCED", "valid": true}` — the previous run's acceptance failure, missing model dependencies and multi-line span boundaries, is fixed), `repro/test_bugMC-1_requeue_timeout_strand.c`, `repro/test_bugMC-1_requeue_timeout_strand.sh`, `repro/run-output.log`, `repro/guest-mc1.log`.
