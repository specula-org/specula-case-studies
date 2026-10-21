# Confirmation Report — asterinas-private-futex-requeue

## Final Result

Reproduced bugs: 4 = 3 NEW + 1 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 4 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred

| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | CR-1 | FALSE POSITIVE | no |

## Entry 1: A timed-out waiter moved to another bucket leaves its entry behind

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-1/debate.md

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

---

## Entry 2: Ordinary REQUEUE with a zero wake quota wakes a waiter

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
using ls
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
using ls
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
using ls
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/worktree/kernel/core/...
I'll follow the skill's two phases. First, Phase 1 evidence gathering: read the cited code, the counterexample, and the campaign context.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
reading /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/worktree/kernel/core/...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec/output/hunt...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec/output/hunt...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec && grep -n...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec && sed -n '...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec && cat MC_h...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/worktree/kernel/core/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/worktree/kernel/core/...
The code path is confirmed in the worktree. Now let me check the model's wake-step semantics, `remove_and_wake_items`, and the Linux reference behavior.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec && sed -n '...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/worktree/kernel/core/...
Code chain confirmed. Now verify the Linux reference semantics for both FUTEX_WAKE and FUTEX_REQUEUE.
using fetch_content: Show the futex_wake function body. Specifically: how is nr_wake used in the loop over waiters — quote the exact lines where futex_wake_mark is called and where the nr_wake count...
using fetch_content: Show the futex_requeue function body. Specifically: how is nr_wake used in the first loop over waiters — quote the exact lines that test the wake quota before waking a waiter (e...
Linux reference confirmed: FUTEX_WAKE wakes before testing the quota (the at-least-one quirk), while FUTEX_REQUEUE tests `++task_count <= nr_wake` *before* waking — nr_wake=0 wakes nobody. Now Phase 1 Step 2: developer-knowledge search (git history, comments, tests).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
The git history is decisive: commit `860bb6c07` changed REQUEUE's wake quota from the raw value (`get_futex_val`) to `futex_val_to_max_count` — over-generalizing the WAKE-only quirk. Let me check tests and the current comment provenance.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/worktree/test/initram...
The trace harness's case-16 is exactly this scenario. Now let me understand the build/run infrastructure (OSDK) and check for reusable artifacts before Phase 2.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
running ls /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/ 2>/dev/null; cat /home/chin39/Documents/play/specula-profile-local...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness/ 2>/dev/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && cat r...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && cat c...
The harness gives a known-good recipe: kernel binary + initramfs → ISO → QEMU boot. Let me verify reusable artifacts and check the case-16 implementation trace (cited evidence for this finding).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && ls -l...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/traces && python...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/traces && head -...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/traces && python...
Implementation trace case-16 confirms: REQUEUE(A→B, 0, 0) woke waiter 2001, wakes=1, moved 0, returned 1. Now Phase 1 Step 3: known-status search (issue tracker + git history).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
using web_search
A potentially matching upstream report exists: asterinas issue #3964. I must verify its actual content — whether it reports THIS exact mechanism (REQUEUE wake-quota normalization) at this site.
using fetch_content
The HTML is too heavy. Let me use the GitHub API for the clean issue body and its comments.
using fetch_content
Issue #3964 (open, 2026-10-06) reports exactly this mechanism: "As with the FUTEX_WAKE arm, the FUTEX_REQUEUE arm normalizes the number of waiters to wake using futex_val_to_max_count()... this normalization should not be applied to FUTEX_REQUEUE to match Linux." Let me check the comment thread and whether any fix PR landed.
using fetch_content
using fetch_content: List all pull requests (open, closed, or merged) that mention futex_val_to_max_count or requeue wake normalization in asterinas/asterinas. Include PR numbers, state (open/closed...
Issue #3964 is open, acknowledged by a maintainer, no fix PR exists → **KNOWN, fix-status: unfixed**. MC-sourced findings proceed to Phase 2 regardless. Let me record Phase 1 and prepare the reproduction. First, environment preflight:
running bash /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh; echo ---; which gcc qemu-system-x86_64 grub...
Environment is ready (46.55 GiB effective memory, gcc on host, docker + dev image available; QEMU/grub live in the container as the harness recipe expects). Let me check the probe's `count_enrolled` semantics before writing the test:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
Phase 1 evidence is complete. Writing the investigation record:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/investigation.md
Now the reproduction test (Phase 2, Level 0 — pure public syscall interface):
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-2_requeue_zero_wake.c
First, the **control run** on the host Linux 7.2.8 kernel (same binary, expected: return 0, no wake):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && gcc -O2...
Control confirmed on Linux 7.2.8: **return 0, no waiter woken**. Now the guest run. Let me verify the probe's enrollment counter and the kernel binary provenance first:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && ls; echo ===; git -C source l...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && diff <(md5sum < source/kernel...
The audited code is exactly what the reused kernel was built from. Now the runner script for the guest run:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-2_requeue_zero_wake.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
The runner exited 0 but produced no guest.log — something silently didn't run. Let me check the work dir and debug:
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc2_gu...
The container never ran the inner script. Let me test the docker invocation directly:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sudo -n docker -H unix:///var...
The heredoc stdin isn't reaching the container's bash. Let me debug the sudo/stdin chain:
running echo "test-stdin" | sudo -n cat 2>&1; echo "sudo_cat_exit=$?"; echo ---; echo "echo FROM_STDIN" | sudo -n docker -H unix:///var/run/docker.sock run --rm -i a...
Found it: `docker run` without `-i` closes stdin, so `bash -s` read EOF and did nothing (exit 0). The harness avoided this by running a script file. Let me restructure the runner accordingly:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc2_inner.sh
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-2_requeue_zero_wake.sh
Now execute the guest run (this is the Level 0 trigger — plain public syscall, no source changes, kernel reused):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
QEMU exited 65 (not the clean 33). Let me inspect the guest serial log:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc2_guest...
The kernel panicked unpacking my initramfs ("CPIO buffer I/O error"). Let me check the kernel's unpack code and compare my cpio with the harness's working one:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '25,60p' source/kernel...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc2_guest...
My cpio is well-formed. Let me find what triggers "CPIO buffer I/O error" in the kernel's initramfs reader:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && grep -rn "CPIO buffer I/O err...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '300,330p' source/kern...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '30,75p' source/kernel...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '185,240p' source/kern...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && grep -n "strip_gzip_header" -...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '258,300p' source/kern...
The parser looks standard. Let me test the exact decompression path (strip header + raw inflate) on both files:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && python3 - <<'...
Revealing: the harness's `initramfs.cpio.gz` is actually an **uncompressed** cpio (header "0707..."), while mine is genuinely gzipped. The kernel took the gzip path and its streaming inflater failed. Let me check the cpio decoder's read pattern and test the kernel's exact streaming behavior:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '50,140p' source/kerne...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '1,30p' source/kernel/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc2_guest...
My simulation bug aside, the real insight: **the harness's working recipe ships an UNCOMPRESSED cpio** (magic `070701`) under the `.cpio.gz` name — the kernel's plain-cpio path handled all 18 harness boots. My genuinely-gzipped file exercises the kernel's streaming gzip path, which fails here (a separate kernel quirk, not my finding). The known-good recipe is plain cpio. Let me verify against a harness boot log, then fix the inner script:
running grep -m1 "unpacking initramfs" /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.spe...
Confirmed — the known-good boots all use the plain-cpio path. Fixing the inner script to match the harness recipe exactly:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc2_inner.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
**BUG REPRODUCED in the Asterinas guest**: REQUEUE(A→B, 0, 0) returned 1 and woke one of two enrolled waiters (word A never changed); Linux control returned 0 and woke none. The fallback enrollment gate was used — let me quickly check why the probe didn't report (the result itself already proves both waiters were enrolled: return 1 + cleanup wake A=1 = 2 waiters total):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sed -n '160,185p' source/kern...
The fallback gate is explained: `probe::enrolled` only counts threads that registered a trace stream (command 1, which scenarios.c does and my test doesn't) — the gate fell back to timing, which is sufficient: the result itself proves both waiters were enrolled (REQUEUE woke 1, cleanup WAKE(A,2) woke the remaining 1, B wake = 0). Let me re-run once to confirm determinism, and read the persistent-findings format:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
Deterministic — identical output on the second run. Saving the control-run evidence and writing the persistent record:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && { echo...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-2/issue.json
running ls /home/chin39/Documents/play/Specula/ 2>/dev/null | head; command -v specula || ls /home/chin39/Documents/play/Specula/bin 2>/dev/null | head -5; python3 /...
running cd /home/chin39/Documents/play/Specula && python3 -m specula findings --work /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-2026100...
running find /home/chin39/Documents/play/Specula -maxdepth 3 -name "*.py" -path "*finding*" 2>/dev/null | head; ls /home/chin39/Documents/play/Specula/lib | head -20...
running cd /home/chin39/Documents/play/Specula && PYTHONPATH=src python3 -m specula findings --work /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-...
running cd /home/chin39/Documents/play/Specula && grep -n "findings" -m3 pyproject.toml; PYTHONPATH=src python3 -c " import specula.persistent_findings as pf import...
running cd /home/chin39/Documents/play/Specula && PYTHONPATH=src python3 -c " from specula.cli import main import sys sys.argv = ['specula', 'findings', '--work', '/...
`issue.json` validates (`valid: true`). All phases complete. Final record:

---

- **Source**: MC (real counterexample: `spec/output/hunt-round2/MC_hunt_s2_zero_wake-bfs.out`, invariant `RequeueWakeQuota`)
- **Novelty**: KNOWN (cite: https://github.com/asterinas/asterinas/issues/3964; fix-status: unfixed) — the issue's second paragraph reports the same mechanism at the same site: the `FUTEX_REQUEUE` arm of `sys_futex()` normalizes the wake count with `futex_val_to_max_count()`, which Linux applies to `FUTEX_WAKE` only. Issue opened 2026-10-06, still open, maintainer acknowledged and invited a fix PR, none merged (verified via issue API and PR search).
- **Location**: `kernel/core/src/syscall/futex.rs:105-109` (REQUEUE arm passes `futex_val` through `futex_val_to_max_count`), `kernel/core/src/syscall/futex.rs:146-151` (`(futex_val as i32).max(1)`), `kernel/core/src/process/posix_thread/futex.rs:455` (`futex_requeue` wakes with the inflated quota and returns `nwakes`)

## Description

`sys_futex` converts `FUTEX_REQUEUE`'s wake count with `futex_val_to_max_count`, which raises 0 to 1. That at-least-one rule reproduces a quirk that belongs to Linux `FUTEX_WAKE` only: `kernel/futex/waitwake.c` calls `this->wake()` before testing `++ret >= nr_wake`, so WAKE(0) still wakes one. Linux `futex_requeue` (`kernel/futex/requeue.c`) instead tests `++task_count <= nr_wake` before waking, so REQUEUE with `nr_wake=0` wakes nobody. Asterinas therefore wakes one waiter per zero-wake-quota REQUEUE and returns 1 instead of 0. The MC counterexample (20 states, `MC_hunt_s2_zero_wake.cfg`) shows REQUEUE(A→B, 0, 0) accepting and removing one of two enrolled waiters, violating `wakes <= rawWake`; the campaign's implementation trace `case-16.ndjson` shows the same kernel-internally (`FutexItemWake accepted → FutexWakeRetain wakes=1 → SysFutexControlReturn result=1`).

## Trigger scenario

Two threads block in `FUTEX_WAIT` on a private futex word A (value 0, expected 0, no timeout). A third thread calls `futex(A, FUTEX_REQUEUE|FUTEX_PRIVATE_FLAG, 0, 0, &B)`. Linux returns 0 and leaves both waiters blocked on A; Asterinas returns 1 and one waiter's `FUTEX_WAIT` returns 0 ("woken") although the futex word never changed and the caller requested zero wakes. This matches the MC trace step for step (`MCWait(1,"A",0)`, `MCWait(2,"A",0)`, `MCCall(1,p,"requeue","A","B",0,0)`).

## Developer intent

Commit `860bb6c07` (2025-06-16, "Adjust and correct parts of the futex implementation code") introduced the defect: before it, the REQUEUE arm used the raw `futex_val` (`get_futex_val`, EINVAL on negative), which matches Linux. The commit factored the WAKE-only quirk into `futex_val_to_max_count` and applied it to REQUEUE as part of a cleanup; the comment it carried cited gVisor's futex test about WAKE only ("The Linux kernel wakes one waiter even if val is 0 or negative"), and the current comment (commit `663175339`) cites `waitwake.c` — again the WAKE quirk. No test in the tree asserts REQUEUE(0, ...) behavior. This reads as an over-generalizing refactor, not a deliberate decision; upstream issue #3964 reports it and a maintainer agreed ("The reported finding sounds reasonable... we'd love to accept a fix").

## Reproduction result

Test: `repro/test_bugMC-2_requeue_zero_wake.c` (portable C; runner `repro/test_bugMC-2_requeue_zero_wake.sh` + container script `repro/mc2_inner.sh`). Level 0 only: plain public futex syscalls, no failpoints, no state injection, no source changes; the campaign kernel image was reused unchanged (identity verified with `harness/identity.py --check-built`; the audited source is byte-identical to the built kernel's source). The enrollment gate uses timing only; the result itself proves both waiters were enrolled (REQUEUE woke 1, cleanup `WAKE(A,2)` woke exactly 1 more, `WAKE(B,2)` woke 0, total 2).

Control, host Linux 7.2.8, same binary (`repro/mc2_host_control.log`):

```
[MC-2] REQUEUE(A->B, 0, 0) returned 0 (errno 0)
[MC-2] waiters whose FUTEX_WAIT returned before cleanup: 0
[MC-2] futex word A = 0 (must be 0: nobody ever stores to it)
[MC-2] cleanup wakes: A=2 B=0, wait_done=2
[MC-2] RESULT: LINUX_CORRECT (return 0, no waiter woken)
```

Asterinas guest (QEMU, KVM, SMP 2, 2G; `repro/mc2_guest/guest.log`; two runs, identical output):

```
[MC-2] start: enrolling two waiters on private futex A
[MC-2] enrollment gate: fallback timed spin (probe unavailable)
[MC-2] REQUEUE(A->B, 0, 0) returned 1 (errno 0)
[MC-2] waiters whose FUTEX_WAIT returned before cleanup: 1
[MC-2] waiter 0: FUTEX_WAIT = 0 (errno 0)
[MC-2] futex word A = 0 (must be 0: nobody ever stores to it)
[MC-2] cleanup wakes: A=1 B=0, wait_done=2
[MC-2] RESULT: BUG_TRIGGERED (return 1, 1 waiter(s) woken; Linux returns 0 and wakes none)
MC2_TEST_DONE
```

The lines demonstrating the bug: return value `1` where Linux returns `0`, and `1` waiter woken with `FUTEX_WAIT = 0` while word A stayed `0` and the caller requested zero wakes. Escalation stopped at Level 0 (triggered); Levels 2–3 were never needed. The wrong-bug check passes: same action sequence as the MC trace, same violated invariant (`RequeueWakeQuota`: wakes=1 > rawWake=0), same code path (confirmed by the audit and the kernel-internal case-16 trace). Note for scope hygiene: the return-count composition question (Linux returns woken+requeued) is a separate finding; for REQUEUE(0,0) the entire divergence (1 vs 0) is attributable to this wake-quota bug, since waking zero would return zero.

Pre-verdict checklist:
1. **Level 0 or Level 1 alone?** Yes — Level 0. A single ordinary public syscall (`FUTEX_REQUEUE|FUTEX_PRIVATE_FLAG` with nonnegative quotas) after two ordinary `FUTEX_WAIT`s; timing help only in the enrollment gate, and the bug is a deterministic logic divergence, not a race.
2. N/A — no Level 2 state injection or Level 3 source patch was used.
3. **Real consumer observing the wrong outcome:** the calling thread receives syscall return value 1 instead of 0 (observable at the `sys_futex` return, `kernel/core/src/syscall/futex.rs`), and the woken waiter thread receives `FUTEX_WAIT = 0` with the futex word unchanged and zero wakes requested (surfaced through the wait epilogue in `kernel/core/src/process/posix_thread/futex.rs:219-229`, which reports success for an already-removed item). Both are in the captured guest output; the consequence is observed, not argued-only.
4. **Permanent or masked?** Permanent. The waiter is woken and the syscall has returned before userspace can react; no downstream kernel mechanism un-wakes the waiter or corrects the count, and the Linux control shows a correct kernel answering 0/0 at the same point, so nothing downstream masks it. Not MASKED.

## Recommendation

Use the raw `futex_val` as the wake quota in the `FUTEX_REQUEUE` arm, matching Linux: `let max_nwakes = (futex_val as i32).max(0) as usize;` (Linux returns EINVAL for negative `nr_wake`; the current `.max(0)` clamp for the requeue count is a separate, benign divergence). Keep `futex_val_to_max_count` for `FUTEX_WAKE`/`FUTEX_WAKE_BITSET` only, and add a regression test asserting REQUEUE(0, N) wakes nobody and returns the woken-plus-requeued count. This matches the fix direction upstream issue #3964's reporter offered to implement.

Artifacts: `confirmation/MC-2/investigation.md` (Phase 1 evidence), `confirmation/MC-2/issue.json` (persistent record, validated), `repro/test_bugMC-2_requeue_zero_wake.c`, `repro/test_bugMC-2_requeue_zero_wake.sh`, `repro/mc2_inner.sh`, `repro/mc2_host_control.log`, `repro/mc2_guest/guest.log`.

---

## Entry 3: A same-bucket REQUEUE with a zero migration quota moves one waiter

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
using ls
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec/output/hunt-round2/MC_hunt_s2_zero...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec/output/hunt...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/worktree/kernel/core/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/worktree/kernel/core/...
Now the resource policy, required before any build work:
reading /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json
running /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh; ls /home/chin39/Documents/play/Specula/runs/aste...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && ls traces/ ha...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && cat repro/mc2...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/worktree/kernel/core/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && head -5 trace...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && ls sr...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && grep...
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness/src/scenarios.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && ls pa...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && sed -...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && cat S...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && ls bu...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && grep -n "Fute...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && ls harness/bu...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && find . -path...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && python3 -c "...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && cat harness/l...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && head -40 harn...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && wc -c harness...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && sed -n '80,16...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && head -1 harne...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && cat analysis-...
running ls ~/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/futex/ 2>/dev/null; find / -maxdepth 6 -name "requeue.c" -path "*futex*" 2>/dev/null |...
running for d in /nix/store/zdkqgrimfyzzh14y2130a7z2jkyfs6bn-source /nix/store/i19358jprz6a9lczdd3igbpk15hvc878-source /nix/store/68sr2r2z4kiyha00b47jbpi99cgyr9q2-so...
running sed -n '570,600p' /nix/store/68sr2r2z4kiyha00b47jbpi99cgyr9q2-source/kernel/futex/requeue.c
running sed -n '600,640p' /nix/store/68sr2r2z4kiyha00b47jbpi99cgyr9q2-source/kernel/futex/requeue.c
Now Phase 1, Step 2 — developer knowledge: git history and comments around the site:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
Phase 1, Step 3 — known-status search. First git history for any fix touching this mechanism:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
using web_search
using fetch_content: List every issue and pull request title (open or closed) shown, with number and state. If none, say "none".
using fetch_content: Reproduce the full body of this issue verbatim: title, state, date, author, and the complete description including any code snippets, reproduction steps, and references to speci...
using fetch_content: List every issue and pull request title shown, with number, state (open/closed), and closed/merged date if visible. If none, say "none".
Let me look at the existing MC-2 repro (same infrastructure, closest precedent) before designing mine:
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-2_requeue_zero_wake.c
Now let me review the MC-2 host wrapper and container recipe to reuse:
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-2_requeue_zero_wake.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && grep -E...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && sed -...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && cat s...
Let me check the violated invariant's definition and the hunt config:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/spec && grep -n...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
Phase 1 evidence is complete. Writing `investigation.md`:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/investigation.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/harness && sed -...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
Now let me check how MC-2 ran its Linux control, then write the test:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && head -2...
Writing the reproduction test:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-3_requeue_zero_move_sa...
Compile-check and run the Linux control first (Level 0, black-box, on the host):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && gcc -O2...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
The unconditional 100ms settle window makes the 4095-round control scan too slow. Fixing the round machine:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-3_requeue_zero_move_sa...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && gcc -O2...
Control passes on Linux 7.2.8 (0.28s, 4095/4095 normal rounds, zero divergences). Now the guest run — packaging with the campaign kernel:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc3_inner.sh
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-3_requeue_zero_move_sa...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
Reproduced at Level 0. Let me verify the full guest log for completeness and correctness:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc3_guest...
Two cosmetic off-by-ones in the log messages ("4096 candidates" should be 4095). Fixing for an accurate record, then re-running both:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-3_requeue_zero_move_sa...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && gcc -O2...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
Reproduced in a second independent guest boot with identical results. Let me check the persistent-findings format for the record:
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/issue.json
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && (specula find...
running ls /home/chin39/Documents/play/Specula/bin 2>/dev/null; find /home/chin39/Documents/play/Specula -maxdepth 2 -name "specula*" -type f 2>/dev/null | head -5;...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && ls /home/chin...
running file /home/chin39/Documents/play/Specula/specula; /home/chin39/Documents/play/Specula/specula findings --work /home/chin39/Documents/play/Specula/runs/asteri...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/issue.json
running /home/chin39/Documents/play/Specula/specula findings --work /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterin...
running grep -n "RequeueMoveQuota ==\|RequeueQuotaAndResult ==" /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-p...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-3/issue.json
running /home/chin39/Documents/play/Specula/specula findings --work /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterin...
All artifacts are in place and the persistent record validates. Final report:

---

- **Source**: MC (real counterexample: `spec/output/hunt-round2/MC_hunt_s2_zero_move_same_bucket-bfs.out`, 22-state trace, invariant `RequeueMoveQuota` violated with `moves=1 > rawMove=0`)
- **Novelty**: NEW — tracker search performed (2026-10-09): all 7 `asterinas/asterinas` issues/PRs matching "requeue" inspected (incl. open #3964, which is a *different* mechanism — cross-bucket requeue + timeout cleanup leak), all futex PRs updated since 2026-09 (#3619, #3576, #2409 — none relevant), full commit history of `update_item_keys` (only the 2022 introduction and the 2024 rewrite, no fix), plus web searches. No report describes a zero-migration-quota same-bucket REQUEUE moving a waiter.
- **Location**: `kernel/core/src/process/posix_thread/futex.rs:500-511` (`update_item_keys` — rekey before quota test); same-bucket dispatch at `futex.rs:378`
- **Severity**: Medium

## Description

When `futex_requeue` operates on two keys that hash to the same futex bucket, it uses `FutexBucket::update_item_keys`, which rekeys a matching item and increments `count` **before** testing `count >= max_count` (futex.rs:500-511). With a migration quota of 0 (`nm=0`), the first remaining waiter is silently rekeyed to the destination word and the loop breaks. The cross-bucket path (`requeue_items_to_another_bucket`, futex.rs:519-535) tests the quota before moving, and Linux 7.2.8 breaks out of its requeue loop before touching any waiter when `task_count - nr_wake >= nr_requeue` (`kernel/futex/requeue.c:600`, verified against the sha256-matched local 7.2.8 source; bucket-independent — `hb1 == hb2` is legal). So `REQUEUE(A→C, 1, 0)` with A and C sharing a bucket wakes one waiter and **moves** the other on Asterinas, while Linux moves none. The migrated waiter is then unreachable via the source key: `WAKE(A)` returns 0 (Linux: 1) and only `WAKE(C)` reaches it.

## Trigger scenario

Identical to the MC counterexample (states 2/6: two waits on A; state 14: `MCCall(1,p,"requeue","A","C",1,0)`): two threads `FUTEX_WAIT_PRIVATE` on word A (value 0); a controller issues `futex(A, FUTEX_REQUEUE_PRIVATE, 1, 0, C)` where C is another aligned word in the same address space hashing to A's bucket (jhash over `addr` and `vmar`; ~1/512 per pair on the SMP=2 guest — 8 of 4096 words collide, confirmed by the kernel bucket oracle). One waiter is woken; the other is rekeyed to C despite the zero migration quota. A subsequent `WAKE(A, 2)` misses it.

## Developer intent

No commit, comment, or test documents the move-then-check ordering (introduced 2022, `895e5c340`; survived the 2024 rewrite `cd9e5d11d`). The opposite intent is stated twice by the developers themselves: the syscall layer comment (`kernel/core/src/syscall/futex.rs:239`) says a quota of "0 or negative ... means no requeues", and the book (`futex.scml:32-33`) documents "requeue up to `max_requeue_waiters`" (up to 0 = none). No in-tree test exercises a zero move quota.

## Reproduction result

Test: `repro/test_bugMC-3_requeue_zero_move_same_bucket.c`; runner `repro/test_bugMC-3_requeue_zero_move_same_bucket.sh` (+ `repro/mc3_inner.sh`). Level 0 (pure black-box): discovery and trigger use only public futex syscalls; the only timing help is a userspace flag handshake plus cooperative `sched_yield()` — no sleeps, no hooks, no source changes. Level 1 cross-check: the campaign kernel's observation-only SPECULA probe (op `0x5350`, cmd 4 = production bucket index, cmd 5 = enrolled count); the trigger itself is unchanged public syscalls. Same binary for the bug run (static guest `/init`, campaign kernel `asterinas-osdk-bin`, sha256 `39ae3549...`) and the Linux 7.2.8 host control. Escalation level reached: **0** (triggered at Level 0; Level 1 cross-check agrees). Commands: `gcc -O2 -Wall -static -pthread -DGUEST -o init ../test_bugMC-3_requeue_zero_move_same_bucket.c` inside the container, packaged and booted per the harness recipe (`timeout 240 qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 2G -smp 2 ...`), `QEMU_STATUS=33` (clean shutdown); control: `gcc -O2 -Wall -o /tmp/mc3_host_control ... && timeout 300 /tmp/mc3_host_control`. Reproduced in two independent guest boots with identical results.

Asterinas guest (bug run, `repro/mc3_guest/guest.log`):
```
[MC-3] LEVEL0: same-bucket zero-quota divergence found at word 398 (of 398 scanned, 397 normal rounds)
[MC-3] L0 formal trigger on pair A=0x4c9b80 C=0x4ca1b8
[MC-3] L0 round: C=0x4ca1b8 REQUEUE(A->C,1,0)=1 WAKE(A,2)=0 WAKE(C,2)=1 returned(after R/W-A/final)=1/1/2 results=0,0 errno=0,0
[MC-3] L0 RESULT: BUG_TRIGGERED -- REQUEUE(A->C, nw=1, nm=0) silently moved one waiter to C (zero migration quota); WAKE(A) returned 0 where Linux guarantees 1; the waiter was only reachable via WAKE(C) (returned 1; Linux: 0)
[MC-3] L1: probe bucket oracle: bucket(A)=186
[MC-3] L1: 8 words share A's bucket; first is word 398 (bucket=186)
[MC-3] L1 round: C=0x4ca1b8 REQUEUE(A->C,1,0)=1 WAKE(A,2)=0 WAKE(C,2)=1 returned(after R/W-A/final)=1/1/2 results=0,0 errno=0,0
[MC-3] L1 RESULT: BUG_TRIGGERED -- ...
MC3_TEST_DONE
```
The decisive lines: `REQUEUE(A->C,1,0)=1 WAKE(A,2)=0 WAKE(C,2)=1` — after the requeue, one waiter returned (the woken one); after `WAKE(A)`, still only one had returned (`returned(after R/W-A/...) = 1/1`) — the second waiter was not woken by the source key — and it returned only after `WAKE(C)` (final=2, both results 0 = woken, not timed out).

Linux 7.2.8 control, same binary (`repro/mc3_host_control.log`):
```
[MC-3] LEVEL0: no zero-quota move divergence in 4095 candidates (normal=4095 anomalies=0) -- consistent with the Linux contract (nm=0 never moves a waiter, any bucket layout)
MC3_TEST_DONE
```
Every candidate pair shows the correct signature `REQUEUE=1, WAKE(A)=1, WAKE(C)=0`; the harness's independent Linux 7.2.8 control (`harness/logs/linux-control.ndjson`, REQUEUE(1,0): `destination_wakes 0, source_wakes 1`) agrees.

Right-bug check: sequence matches the CE (two waits on A → `REQUEUE(A→C,1,0)` → later `WAKE(A)` misses the waiter); the violated property is the same one (`RequeueMoveQuota == moves <= rawMove`: one waiter moved with quota 0); the root-cause path is the cited one — the Level-1 oracle independently proves A and C share bucket 186 (the same-bucket dispatch condition at futex.rs:378), and the harness's implementation trace case-05 shows the identical mechanism kernel-side (`FutexUpdateItemKey {moves:1, entryKey:B}` after `requeue nw=1 nm=0` same bucket, then `WAKE(A)` → result 0).

Pre-verdict checklist:
1. **Level 0 or Level 1 alone?** **Yes** — Level 0 (real public futex syscalls; only cooperative-yield timing help). The Level-1 probe cross-check was confirmatory, not required.
2. N/A — no state injection or source patch used; the same-bucket pre-condition is reached by ordinary address choice (~1/512 of aligned word pairs), found black-box by the test itself.
3. **Real consumer:** the requeueing thread — any caller of `futex(..., FUTEX_REQUEUE_PRIVATE, nw≥1, 0, C)` that later wakes the source word (`kernel/core/src/syscall/futex.rs:236-248` is the entry it calls). It observes `WAKE(A)` returning 0 where Asterinas' own syscall-layer comment (`syscall/futex.rs:239`), the book, and Linux all guarantee the waiter remains on A. The stranded waiter itself only completes via `WAKE(C)` — a word the caller explicitly declined to migrate to.
4. **Permanent?** The rekeyed item stays keyed under C until woken via C or timed out — no downstream mechanism re-keys it (wake matches by key, cleanup removes by waker). In the test the release was the test's own `WAKE(C)` cleanup, not a system safeguard; a program that never wakes C blocks the waiter until timeout (5 s here; forever if untimed). Not masked.

## Recommendation

In `update_item_keys`, gate the move on the quota before rekeying, matching both the cross-bucket path and Linux:

```rust
for item in self.items.iter_mut() {
    if count >= max_count {
        break;
    }
    if item.key.match_up(key) {
        item.key = new_key.clone();
        count += 1;
    }
}
```

With `max_count == 0` this moves nothing (loop breaks immediately); for `max_count >= 1` the behavior is unchanged (the orderings differ only at 0). Add a regression test asserting `REQUEUE(same-bucket A→C, 1, 0)` leaves the second waiter reachable via `WAKE(A)` (the persisted repro `repro/test_bugMC-3_requeue_zero_move_same_bucket.c` is directly reusable). Persistent record written and validated: `confirmation/MC-3/issue.json`.

---

## Entry 4: REQUEUE returns only the number of woken waiters

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-4/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Continuing MC-4 confirmation. I was in Phase 1 Step 2/3 (developer knowledge + known-status). Let me finish checking the two broad futex PRs and the book's return-value documentation.
running gh pr view 2515 --repo asterinas/asterinas --json title,body,files -q '.title + "\nFILES: " + (.files | map(.path) | join(", ")) + "\n---\n" + .body' 2>&1 |...
running gh pr view 2815 --repo asterinas/asterinas --json title,body,files -q '.title + "\nFILES: " + (.files | map(.path) | join(", ")) + "\n---\n" + .body' 2>&1 |...
PR 2515 is about WAIT return values for LTP checkpoints (different mechanism); PR 2815 is cosmetic. Neither matches. Now the syscall-layer call chain and the book's return-value doc:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
The book documents the operation but not the return value. Let me see the full REQUEUE arm in the syscall layer and the Linux same-address path, then record everything in investigation.md.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
running sed -n '530,580p' /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/requeue.c
running sed -n '60,110p' /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/requeue.c; echo "===futex_...
Linux same-address REQUEUE counts the no-op move in `task_count` (requeue.c:607-610: `++task_count` then wake-or-requeue; requeue_futex is a no-op for same bucket but still counted). One more known-status check — omnibus issue #3920 "Soundness bugs uncovered during agentic scan" could contain this defect:
running gh issue view 3920 --repo asterinas/asterinas --json body -q .body 2>&1 | grep -i -B3 -A6 "requeue" | head -40
running gh issue view 3920 --repo asterinas/asterinas --json body -q .body 2>&1 | head -30; echo "===search requeue in all asterinas issues incl closed==="; gh searc...
#3920 is unsafe-rust soundness, unrelated. The only "requeue" tracker hit (#3964) covers quota normalization and cleanup-bucket bugs, not the return count. **Novelty: NEW** is established. Now let me write the investigation record, then study the MC-3 repro pattern for my test.
reading /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-3_requeue_zero_move_sa...
I have the full MC-3 pattern. MC-4's reproduction is simpler — the divergence is deterministic (return value of a single syscall), no bucket discovery needed. Let me verify three details before writing the test: `futex_val_to_max_count` behavior for nw∈{1,2}, the instrumentation being observation-only in `futex_requeue`, and Linux's same-address handling.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-...
running grep -n "uaddr1 == uaddr2\|unlikely(!cmpval" /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/fute...
running sed -n '390,425p' /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/linux-v6.16.5/kernel/futex/requeue.c
All evidence gathered. The same-address EINVAL applies only to requeue_pi; ordinary REQUEUE proceeds and counts. Writing the Phase 1 investigation record now.
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-4/investigation.md
Phase 1 complete. Now Phase 2 — first check how the sibling confirmations produced their host control logs, then write the MC-4 test.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc3_host_...
Pattern confirmed. Writing the MC-4 reproduction test now:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-4_requeue_return_count.c
Now run the Linux control natively first (Level 0 + Level 1 in one binary):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && gcc -O2...
Linux control: **15/15 rounds LINUX_CORRECT** — REQUEUE returns 2 in both CE shapes (F03 distinct: ret=2, WAKE(dst)=1, WAKE(src)=0; F06 same-address: ret=2, WAKE(src)=1), control case matches, zero anomalies. Let me add the command header to the control log, then set up the guest run.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && sed -i...
47 GiB available — plenty. Writing the container inner script and outer runner:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/mc4_inner.sh
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-4_requeue_return_count.sh
Now executing the full reproduction runner (Linux control summary + Asterinas guest boot). The control log already exists, so it will be reused:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
**Level 0 (pure black-box) triggered the bug 9/9 CE rounds** — F03 distinct-address ret=1 (Linux 2), F03 same-bucket ret=1, F06 same-address ret=1, control matches. The Level-1 probe gate failed (-99: enrollment oracle never reported ≥2) — my test skipped the probe's key registration (cmd 3) that MC-3 did before using the enrollment counter. Let me verify against MC-3's guest log and fix:
running grep -E "L1|probe" /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/...
MC-3's L1 registered key A (cmd 3) before the enrollment oracle — that's what my test missed. Fixing:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-4_requeue_return_count.c
Re-running both the Linux control (source changed, though the change is probe-guarded) and the guest:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && rm -f m...
All 15 CE rounds triggered (Level 0 + Level 1 with probe-proven enrollment), 0 anomalies. But my test's final tally has a reporting bug: control matches count into `n_linux`, so the summary line says MIXED even though every CE round says BUG_TRIGGERED. Fixing the tally and re-running for a clean final record:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-4_requeue_return_count.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && gcc -O2...
`RESULT: BUG_TRIGGERED` is now correct, but `control_match=0` undercounts (the c==3 branch prints but no longer tallies). One-line fix and a final clean run:
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugMC-4_requeue_return_count.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && rm -f m...
Final run is clean and fully consistent: host control 12/12 CE rounds correct (ret=2), guest 15/15 CE rounds BUG_TRIGGERED (ret=1), 3/3 control matches both sides, 0 anomalies. Let me preserve the full logs and check the persistent-findings reference:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && cp /tmp...
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md 2>/dev/null | head -60
MC-4 is an unresolved REPRODUCED finding, so I write the persistent record `confirmation/MC-4/issue.json`. Let me see the full format first:
running sed -n '60,120p' /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
running for d in MC-1 MC-2 MC-3 CR-1; do f="/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue...
MC-3's issue.json shows the local convention. Let me check whether the `source/` checkout is instrumented (to pick correct line numbers for the dependencies):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/source && git status --short | h...
`source/` is the instrumented checkout. Getting its line numbers for the dependency spans:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/source && grep -n "pub(self) fn...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/MC-4/issue.json
Validating the issue.json spans and running the specula validator:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && python3 - <<'EOF' import json...
The "source" root resolves against the source checkout, not the run root. Re-checking with the right base:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && python3 - <<'EOF' import json...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && timeout 120 python3 -m specul...
running ls /home/chin39/Documents/play/Specula/src/specula/.. 2>/dev/null | head -3; cd /home/chin39/Documents/play/Specula && (timeout 120 python3 -m specula findin...
running cd /home/chin39/Documents/play/Specula && (command -v specula || ls src/specula/__main__.py 2>/dev/null || ls src/specula/cli* 2>/dev/null; grep -rn "def mai...
running cd /home/chin39/Documents/play/Specula && grep -n "findings" src/specula/cli.py | head -8; echo "---"; PYTHONPATH=src timeout 180 python3 -c " from specula.c...
Validation passed (`"valid": true`). All deliverables are complete. Final report:

---

- **Source**: MC (real TLC counterexamples: `spec/output/hunt-round2/MC_hunt_s2_return_count-bfs.out`, 30 states; `MC_hunt_s2_same_address-bfs.out`, 24 states)
- **Novelty**: NEW — searched the upstream tracker on 2026-10-10: all issues matching "futex" (~40) and "requeue" (1: #3964, which covers the cleanup-bucket bug and the wake-quota normalization, *not* the return count), all PRs matching "futex" (~30: 2515 = WAIT return value for LTP, 2815 = cosmetic, 2404/2424/3331/2146/2190/… none touch the REQUEUE return count), omnibus #3920 (unsafe-rust soundness, no requeue mention), issue #35 (atomicity/keys). Nothing reports wakes-only REQUEUE return semantics at this site.
- **Location**: `kernel/core/src/process/posix_thread/futex.rs:381` (`Ok(nwakes)`), with `:353-355` (same-address `futex_wake` shortcut dropping `max_nrequeues`) and `:500-534` (both movement helpers return `()`, so the moved count is lost)

## Description

Asterinas `futex_requeue` returns `Ok(nwakes)` — only the number of waiters woken — for ordinary `FUTEX_REQUEUE`. Linux (pinned v6.16.5 `kernel/futex/requeue.c:584-610,691`) increments `task_count` for **every** matching waiter, woken or requeued (including the no-op same-key requeue when `uaddr1 == uaddr2`), and returns that total. Both movement helpers (`update_item_keys`, `requeue_items_to_another_bucket`) return `()`, so the caller cannot add the moved count even if it wanted to; identical addresses take a shortcut to `futex_wake` that discards `max_nrequeues` entirely. `REQUEUE(A→B, 1, 1)` with two waiters on A returns 1 on Asterinas and 2 on Linux; `REQUEUE(A→A, 1, 1)` likewise. The man-pages 6.19 `FUTEX_REQUEUE(2const)` page describes only a wake count, but the campaign calibration (contracts.md) fixes the Linux implementation as the versioned reference, and the running Linux 7.2.8 control returned 2 in both shapes.

## Trigger scenario

Exactly the MC counterexample steps: (1) two threads call `FUTEX_WAIT_PRIVATE(A, 0)` and block, both enrolled; (2) a third thread calls `FUTEX_REQUEUE_PRIVATE(A, nr_wake=1, nr_requeue=1, B)` — or the same-address variant `REQUEUE(A, 1, 1, A)`. One waiter is woken, one is moved to B (or counted as a same-key requeue by Linux); Asterinas returns 1, Linux returns 2. Fully deterministic — no race, no bucket-layout dependence (reproduced on both the cross-bucket `requeue_items_to_another_bucket` path and the same-bucket `update_item_keys` path).

## Developer intent

No stated intent found. `Ok(nwakes)` and the same-address shortcut both date from the original 2022 "implement posix thread" commit (1e89933a99); no comment, commit message, book entry (`futex.scml` documents the operation but not the return value), or test asserts wake-only return semantics. The nearest developer commentary (PR 2515 body) treats futex return values as load-bearing for LTP `tst_checkpoint` — evidence that callers consume these counts, not that this deviation is intended. Falling back to engineering principle: Linux-compat syscall semantics per the campaign's pinned Linux source.

## Reproduction result

Test: `repro/test_bugMC-4_requeue_return_count.c` + runner `repro/test_bugMC-4_requeue_return_count.sh` (container recipe `repro/mc4_inner.sh`); guest = campaign kernel image (source 0c6053709, observation-only instrumentation), QEMU KVM, SMP 2, clean shutdown (QEMU_STATUS=33); control = same binary natively on host Linux 7.2.8. Full logs: `repro/mc4_guest/guest.log`, `repro/mc4_host_control.log`, `repro/mc4_combined_run.log`.

**Asterinas guest — Level 0 (pure black-box public syscalls), BUG_TRIGGERED in all 9 CE rounds:**
```
[MC-4] L0-F03 round 1: REQUEUE(0x4c9b80->0x4c9b84,1,1)=1 WAKE(dst)=1 WAKE(src)=0 done(afterR/final)=1/2 results=0,0 errno=0,0
[MC-4] L0-F03 round 1: BUG_TRIGGERED (ret=1 but wakes+processed=2: one waiter woken by REQUEUE, one moved to dst (WAKE(dst)=1) and provably enrolled)
[MC-4] L0-F03sb round 1: REQUEUE(0x4c9b80->0x4ca1b8,1,1)=1 WAKE(dst)=1 WAKE(src)=0 ... BUG_TRIGGERED   (same-bucket destination, update_item_keys path)
[MC-4] L0-F06 round 1: REQUEUE(0x4c9b80->0x4c9b80,1,1)=1 WAKE(dst)=-1 WAKE(src)=1 ... BUG_TRIGGERED   (same address, futex.rs:353-355 shortcut)
[MC-4] L0-CTRL round 1: REQUEUE(0x4c9b80->0x4c9b84,2,1)=2 WAKE(dst)=0 WAKE(src)=0 ... CONTROL_MATCH (both kernels return 2 when nothing is moved)
```
**Level 1 (kernel enrollment oracle proves ≥2 waiters queued before the syscall): BUG_TRIGGERED in all 6 CE rounds.**
```
[MC-4] totals: linux_correct_ce=0 bug_triggered=15 control_match=3 anomalies=0
[MC-4] RESULT: BUG_TRIGGERED -- FUTEX_REQUEUE returned only the wake count while a waiter was provably woken AND another provably moved (or counted); Linux returns wakes+requeues
MC4_TEST_DONE
```
**Linux 7.2.8 control (same binary, no -DGUEST):**
```
[MC-4] totals: linux_correct_ce=12 bug_triggered=0 control_match=3 anomalies=0
[MC-4] RESULT: LINUX_CONTROL_CORRECT -- REQUEUE returned wakes+requeues in every CE round
```
The round signatures match the invariant decomposition: `WAKE(dst)=1, WAKE(src)=0`, both waits completing with 0 (not ETIMEDOUT) proves exactly two waiters enrolled — one woken (`wakes=1`), one moved (`processed=1`) — so the syscall must return 2; Asterinas returns 1. The `(2,1)` control returning 2 on both kernels isolates the divergence to the uncounted moved waiter. Same actions, same order, same invariant (`RequeueReturnCount`), same code path as the finding.

## Recommendation

Make both movement helpers return the number of moved items (`usize`), return `Ok(nwakes + nrequeues)` at futex.rs:381, and fix the same-address branch: either drop the futex.rs:353-355 shortcut (Linux dispatches ordinary REQUEUE through `futex_requeue` even for `uaddr1 == uaddr2`) or replicate the count semantics — wake up to `max_nwakes`, then count up to `max_nrequeues` of the remaining matching waiters as no-op requeues. Add a regression test asserting `REQUEUE` return == woken + moved against a Linux control. The persistent record is `confirmation/MC-4/issue.json` (validated `valid: true`).

## REPRODUCED checklist

1. **Did Level 0 or Level 1 alone trigger it?** **Yes.** Level 0 (pure black-box): the trigger is one plain `syscall(SYS_futex, A, FUTEX_REQUEUE_PRIVATE, 1, 1, B, 0)` from an ordinary threaded program; the only timing help is a cooperative armed-flag spin + `sched_yield()` before the syscall (enrollment gate). All 9 Level-0 CE rounds read BUG_TRIGGERED. Level 1 added only the observation probe (enrollment oracle); no state injection, no source patch was used or needed.
2. **N/A** — no Level 2/3 escalation occurred. The pre-condition (two waiters blocked on A) is produced by the real-API sequence `FUTEX_WAIT_PRIVATE(A,0)` × 2, instantiating CE steps `MCWait(1,"A",0)`, `MCWait(2,"A",0)` directly.
3. **Real consumer observing the wrong outcome:** the syscall caller itself — the calling thread receives 1 instead of 2 at the syscall boundary (`kernel/core/src/syscall/futex.rs:144` returns it verbatim); demonstrated live in the reproduction, not argued-only. Production consumers of the same value: glibc/musl condvar-style REQUEUE loops and LTP `tst_checkpoint` logic (PR 2515 documents these counts as load-bearing).
4. **Permanent, not masked:** the wrong value is a completed syscall output consumed at return; no sync/loopback/resend/caller guard later corrects a too-low REQUEUE count — nothing downstream re-derives it, and no later kernel action repairs it. Not a transient snapshot.

---

## Entry 5: A user value update and WAKE can overlap WAIT registration, including the unlocked fault-retry window

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/CR-1/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && ls repro/ rep...
Workspace preserved: Phase 1 (`investigation.md`) and the test/scripts are written; the guest run has not executed yet. Resuming at provenance verification, then the run:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sudo -n docker -H unix:///var...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && ls -la | head; ls -la source...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sudo -n docker -H unix:///var...
Git's dubious-ownership check fails for root inside the container. Run the identity check on the host instead:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && python3 .specula-output/harne...
Provenance verified — the prebuilt kernel matches source 0c6053709 + recorded instrumentation. Quick memory check, then execute the reproduction run:
running /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
Level 0 + Level 1 results are in: **zero lost wakes across 371,000 racing iterations** (Phases A–D all show both woken and EAGAIN outcomes — the race genuinely interleaved both ways; the madvise check confirms the fault-retry window really opened in B/D; Phase E validates the EAGAIN mismatch path). 

Before settling the ladder, one more escalation is warranted: the finding specifically names the *unlocked fault-retry window*, and Level 3 (a kernel-side delay inside that exact window) would widen it deterministically. Let me check the cost of an incremental kernel rebuild:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && du -sh .specula-output/harnes...
`source/` and the CR-1 worktree are content-identical (only `.git` differs). Plan for Level 3: patch a *copy*, shadow-mount it at the same container path (`/work/source`) so cargo's fingerprints stay valid for an incremental rebuild, and reuse the copied target dir at its original path. Checking sizes first:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && du -sh source source/.git .sp...
`source` is 42M, target 3.6G — the shadow-mount plan is cheap. Setting up the Level 3 build tree (patched copy + copied target, so the harness's recorded kernel binary is never touched):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && ls .specula-output/harness/bu...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && cp -a .specula-output/harness...
The target dir is root-owned (built in-container). Redo the copy inside a container as root — first clean the partial copy:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && rm -rf .specula-output/confir...
Target copied. Now make `l3run` writable and check `tr::stamp()`'s type for the patch:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sudo -n docker -H unix:///var...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation/CR-1/l3run/source/kernel/c...
Verify the patch is the only difference from the original `source/`:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && diff -r source .specula-outpu...
Exactly the intended 6-line patch. Now add `CR1_L3` guards to the C test (skip A/C/E, reduce B/D counts since every faulted iteration now costs ≥200µs):
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugCR-1_lost_wake_race.c
Let me re-read the current `waker_fn` to craft disjoint edits:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && sed -n...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugCR-1_lost_wake_race.c
Now the Level 3 inner script and host runner (mounted so the patched source sits at `/work/source` and the copied target at its original path — preserving cargo fingerprints):
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/cr1_l3_inner.sh
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugCR-1_lost_wake_race_l3.sh
Quick syntax check of both build variants before launching the expensive L3 build:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue && sudo -n docker -H unix:///var...
Both variants compile. Memory check, then launch the Level 3 run (rebuild + boot, bounded):
running /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
The build needs to fetch a git dependency (`inherit-methods-macro`) and the container's network attempt failed. The original harness build had fetched it into the (now gone) ephemeral `/root/.cargo`. Let me diagnose container network reachability:
running env | grep -i proxy; sudo -n docker -H unix:///var/run/docker.sock run --rm asterinas/kernel-dev:0.18.1-20260926 bash -c 'timeout 20 curl -sI https://github....
The host uses a proxy (`192.168.0.240:10809`) that isn't passed into containers, and the image's cargo cache lacks the needed git dep. Testing with proxy passed, then updating the runner:
running sudo -n docker -H unix:///var/run/docker.sock run --rm -e http_proxy=http://192.168.0.240:10809 -e https_proxy=http://192.168.0.240:10809 asterinas/kernel-de...
editing /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro/test_bugCR-1_lost_wake_race_l3.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/repro && timeout...
Level 3 run completed: the patched kernel (new sha `dbebc79…`, distinct from the harness binary) held the fault-retry window open ~200µs, and the store+WAKE landed *inside* that window ~22,500 times (distribution flipped from 72% woken to 3.5% woken vs unpatched — the adversarial interleaving was forced at maximum frequency) — **zero lost wakes**. Let me verify the raw logs contain no anomaly lines and capture the exact outputs:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output && grep -c "CR1_...
All evidence collected and verified. Appending the Phase 2 reproduction record to the investigation file, then emitting the verdict:
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z/asterinas-private-futex-requeue/.specula-output/confirmation...
All deliverables complete. Final report:

---

- **Source**: Code Review (the Scenario-1 MC hunt configs ran with no violation — no counterexample exists for this finding)
- **Novelty**: NEW (searched upstream issues, PRs, commit history, and current upstream `main`; historical #981, #2306, #1587 are different mechanisms — non-atomic read, page-fault-in-atomic-mode, and cleanup-path removal — none reports this registration-window mechanism)
- **Location**: `kernel/core/src/process/posix_thread/futex.rs:96-119` (fault-retry registration loop; supporting: `thread_local.rs:102-135`, `ostd/src/sync/wait.rs:192-201,262-275`)

## Description

The finding hypothesizes that a user value store plus `FUTEX_WAKE` can overlap `futex_wait_bitset`'s load/compare/enqueue — including the unlocked fault-retry window where the bucket lock is dropped to resolve a page fault — and let a wait miss a required wake. The audit shows the contract holds structurally: the load, compare, and enqueue are one continuous bucket-lock hold (`futex.rs:96-168`), matching Linux's locked `futex_wait_setup`/`queue_futex`; `futex_wake_bitset` dequeues and wakes under the same bucket lock; the fault path re-acquires the lock and re-loads before comparing (a wake that slipped into the unlocked window is caught by the mismatch → `EAGAIN`); and the enqueue→park gap is covered by the ostd `has_woken` latch. Every serialization case yields `EAGAIN` (load saw the store) or woken (wake found the enqueued item) — a missed wake requires the wake's critical section to land between load and enqueue, which the single lock hold makes impossible. There is no defect: the hypothesized harm cannot occur through the real interface.

## Trigger scenario

Two pinned threads (SMP 2), one private futex word in an anonymous page; per iteration the waker does `atomic_store(word,1)` then `FUTEX_WAKE_PRIVATE(1)` exactly once while the waiter calls `FUTEX_WAIT_PRIVATE(word, 0, timeout=250ms)`. For this protocol a waiter timeout would be a missed required wake. The fault-retry window is opened by `madvise(MADV_DONTNEED)` before each wait (real syscall; verified the discard works), so the locked load faults and the kernel takes the unlock→handle-fault→relock→reload path while the store+WAKE races into the window.

## Developer intent

The lock-first structure is deliberate: commit `5b9106431` ("Add a method that disables page fault handlers", the #2306 atomic-mode repair) introduced the fault-retry loop, and `with_page_fault_disabled`'s doc (`thread_local.rs:112-119`) mandates exactly this exit-atomic-mode/resolve/retry discipline. The comment "Lock the futex bucket first to avoid race conditions" (`futex.rs:97`) states the intent. Historical lost-wakeup fix `6c4f56723` and cleanup fix `888eecb35` (issue #1587) addressed different mechanisms. No developer commentary promises tolerance of a missed wake; the code asserts the opposite.

## Reproduction result

Test executed on the real system (QEMU q35/KVM, SMP 2, 2G, campaign kernel 0c6053709, identity verified `c39392f9…`). Command: `bash .specula-output/repro/test_bugCR-1_lost_wake_race.sh` (Levels 0–1) and `bash .specula-output/repro/test_bugCR-1_lost_wake_race_l3.sh` (Level 3: kernel rebuilt from a copy with a 6-line timing-only patch holding the unlocked fault window open ~200µs; rebuilt kernel sha256 `dbebc79c…`; harness binaries untouched).

Level 0 + 1 (`repro/cr1_guest/guest.log`):
```
CR1_MADVISE_CHECK ret=0 word_after=0 works=yes
CR1_PHASE A iters=200000 woken=217 eagain=199783 eintr=0 timeout=0 other=0
CR1_PHASE B iters=50000 woken=36124 eagain=13876 eintr=0 timeout=0 other=0
CR1_PHASE C iters=100000 woken=45274 eagain=54726 eintr=0 timeout=0 other=0
CR1_PHASE D iters=20000 woken=17092 eintr=2908 eagain=2908 eintr=0 timeout=0 other=0   (woken=17092 eagain=2908)
CR1_PHASE E iters=1000 woken=0 eagain=1000 eintr=0 timeout=0 other=0
CR1_ANOMALY_WAKE_COUNTED_BUT_NOT_WOKEN 0
CR1_DONE
```
Level 3, widened kernel-side fault window (`confirmation/CR-1/l3run/.specula-output/repro/cr1_l3_guest/guest.log`):
```
CR1_MADVISE_CHECK ret=0 word_after=0 works=yes
CR1_PHASE B iters=20000 woken=691 eagain=19309 eintr=0 timeout=0 other=0
CR1_PHASE D iters=5000 woken=1763 eagain=3237 eintr=0 timeout=0 other=0
CR1_ANOMALY_WAKE_COUNTED_BUT_NOT_WOKEN 0
CR1_DONE
```
Zero `CR1_LOST_WAKE` / unexpected-errno / counted-but-lost lines in both raw logs. The woken+EAGAIN mix in every racy phase proves both interleaving directions occurred; the Level 3 distribution flip (72%→3.5% woken) shows the store+WAKE completed inside the widened unlocked window ~22,500 times — the exact hypothesized overlap — and the locked reload caught it every time. Escalation: L0 (200k) no trigger; L1 (170k incl. 70k fault-window) no trigger; L2 inapplicable (the hypothesized bad state needs the wake between load and enqueue, unreachable through any real-API sequence because both sit under one continuous lock hold — fabricating it would require removing the lock); L3 (25k) no trigger. Expected correct behavior (per Linux contract): no timeout ever occurs — observed.

## Recommendation

Close as a non-defect; no code change needed. The registration contract is correct and Linux-equivalent. Optional hardening (not a bug fix): the cleanup FIXME at `futex.rs:207-214` about `pause_timeout` return codes on the woken path remains a cosmetic wart already acknowledged upstream.

---
