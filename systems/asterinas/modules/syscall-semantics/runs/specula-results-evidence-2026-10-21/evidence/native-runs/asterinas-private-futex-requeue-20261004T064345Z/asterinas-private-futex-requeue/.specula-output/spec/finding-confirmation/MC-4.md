# MC-4

Status: REPRODUCED
Run: asterinas-private-futex-requeue-20261004T064345Z

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
