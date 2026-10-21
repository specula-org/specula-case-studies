# Confirmation Report — asterinas-unix-dgram-scm-rights

## Final Result

Reproduced bugs: 2 = 0 NEW + 2 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 2
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 4
Dispositions: 4 total = 2 reproduced + 0 env-limited + 0 masked + 2 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred

| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | CR-1 | FALSE POSITIVE | no |
| 4 | CR-2 | FALSE POSITIVE | no |

## Entry 1: AST-32: Failed SCM_RIGHTS number publication retains an installed FD

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-1/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
Now let me explore the environment — the worktree, the counterexample log, and the finding work dir.
running ls /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
There's prior state in the work dir. Let me check what previous turns did.
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-1/investigation.md
Phase 1 investigation is complete from a prior turn. Let me check what else exists — logs, issue.json, and the repro dir.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; ls -la repro/ 2...
A prior turn left substantial state. Let me understand what happened — check turn01_A.log, debate.md, guest.log, and whether the MC-1 repro test exists.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; find . -name "*MC-1*" -o -name...
The prior attempt completed the reproduction in the Asterinas guest (guest.log shows the leak triggered) and a Linux control run, but crashed during final artifact validation: the repro test file `repro/test_bugMC-1_failed_number_install.c` is missing, and issue.json dependency boundaries didn't match. Let me understand the requirements and the state.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
The picture is clear: the prior attempt compiled the test from `.specula-output/repro/test_bugMC-1_failed_number_install.c` into `build/root/init`, ran the guest, but the `.c` file later vanished and validation failed on dependency boundaries. Let me check the actual source-root files to fix the boundaries, and inspect the binary that still exists.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; grep -n "fn write_to" source/ke...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; ls worktree 2>/dev/null | head;...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running cat /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json 2>/dev/null; echo "====="; ls /home/chin39/Documents/play/S...
running LOCK=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/heavy.lock; ls -la $(dirname $LOCK) 2>/dev/null; cat $LOCK 2>/dev...
The worktree matches the pin with harness instrumentation; memory is ample. Now let me examine the compiled test binary to understand the prior test's exact behavior, so I can faithfully reconstruct the source.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Let me disassemble the key functions to confirm the exact fault-layout math the prior test used.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
The guest.log confirms the full reproduction. Now let me verify the worktree matches the build tree (RUNROOT/source) so I can soundly reuse the existing build, then reconstruct the test.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; W=.specula-output/confirmation/...
Worktree and build tree are identical for all relevant files — reuse is sound. Let me read the cited code in the worktree to ground the report's citations.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Let me see the rest of `do_faulting_recv` (the leak-content read path) to be faithful.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Let me fill in the remaining gaps of main's disassembly (the retry-fd cleanup and result computation).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
I now have the complete original test semantics from the disassembly. Let me write the faithful reconstruction of the repro test.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugMC-1_failed_number_install.c
Now the Linux control run on the host — compile and execute.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; gcc -O2 -g -Wal...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugMC-1_failed_number_install.c
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; gcc -O2 -g -Wal...
Linux control run is byte-identical to the prior control log — no leak, prefix reported as 24, `invariant_matches_linux:1`. The reconstruction is faithful. Now the Asterinas guest run — verify docker access, then rebuild the initramfs + ISO.
running sudo -n docker -H unix:///var/run/docker.sock images 2>&1 | head -5; echo "---"; sudo -n docker -H unix:///var/run/docker.sock ps -a 2>&1 | head -5
Docker works. Now rebuild the guest initramfs + ISO with the reconstructed test (bounded timeout, same container/resource limits as the prior run).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Build succeeded. Now boot the guest and capture the reproduction run.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
**REPRODUCED.** The fresh Asterinas guest run shows the leak — byte-identical to the prior run. Let me persist the fresh evidence logs.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; grep -a "MC1_"...
Both logs persisted. Now fix the issue.json dependency boundaries that failed validation — check each boundary line for uniqueness in the source root.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/source; for pat in "fn write_to(...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/source; echo "--- ctrl_msg write...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/source; sed -n '218,262p' kernel...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/source; echo "--- result.map_err...
All boundary candidates verified. Let me check the counterexample logs exist, then fix issue.json's dependencies.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; ls -la spec/out...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-1/issue.json
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; python3 -c "import json; json.l...
running ls /home/chin39/Documents/play/Specula/src/specula/__init__.py 2>/dev/null; which python3; python3 -c "import sys; sys.path.insert(0, '/home/chin39/Documents...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; PYTHONPATH=/home/chin39/Documen...
issue.json validates. Let me verify the AST-32 dataset citation in contracts.md and append a Phase-2 addendum to investigation.md.
running grep -n "AST-32" /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/contracts.md | head -5
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation...
Let me pull the key counterexample states from the TLC log for accurate citation in the final report.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; grep -an "NoFai...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; awk '/^State 3[...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output; awk '/^State 31...
The classifier blocked that command over quoting; let me extract the State 31 fields with a simpler Python one-liner instead.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output && python3 - <<...
State 31 confirms the CE's final state matches the live run exactly. All artifacts are complete and validated. Final report:

---

- **Source**: MC (real TLC counterexamples: `spec/output/validation-20261010T015405Z/MC_hunt_AST32_install.log` — "Invariant NoFailedNumberInstalled is violated", 31-state trace; `MC_hunt_AST32_report.log` — "Invariant ReportedPrefixMatchesLinux is violated")
- **Novelty**: KNOWN (cite: AST-32 / asterinas-bug-findings-2026-08, retained as a prior source lead in parallel-scopes-2026-10-04/scm-rights/contracts.md SCM-05/06/09; fix-status: unfixed — the Phase-1 tracker search covered upstream open and closed issues and merged PRs including PR #2176's full review discussion and found no report of this mechanism at this site, and upstream main still shows insert-then-write with the same TODO comment; this is its first reproduction)
- **Location**: kernel/core/src/net/socket/unix/ctrl_msg.rs:184 (install at `table.insert`, publish at :203, awareness comment at :199-201); kernel/core/src/net/socket/util/message_header.rs:115 (error swallow, zero-length report)

## Description

`FileMessage::write_to` installs each referenced file into the receiver's file table (ctrl_msg.rs:184) before copying the FD integer to the user control buffer (ctrl_msg.rs:203). When the integer copy faults, the `?` returns `Err`, but nothing removes the just-installed entry. `ControlMessage::write_all_to` (message_header.rs:115-118) then swallows the error, sets MSG_CTRUNC, and does not add the partially-written message to `len`, so `recvmsg` succeeds with the payload length while reporting `msg_controllen = 0`. The receiver is left holding an open fd whose number was never published to user space. In the mid-list fault case, the successfully published prefix is also misreported: two valid FD integers sit in the user's buffer, yet the reported control length is 0 instead of the delivered prefix length. Linux v6.15 orders reserve (`get_unused_fd`) → `put_user` → `fd_install` with `put_unused_fd` on copy failure, so the failed entry is never installed there, and `scm_detach_fds` reports `CMSG_SPACE(i*4)` = 24 for 2 of 4 delivered FDs.

## Trigger scenario

`socketpair(AF_UNIX, SOCK_DGRAM|SOCK_NONBLOCK)`; sender `sendmsg` with one SCM_RIGHTS cmsg of 4 fds `[A,B,A,B]` plus a 1-byte payload; receiver maps a 2-page region, mprotects page 2 PROT_NONE, and places the 32-byte control buffer so the 16-byte cmsghdr fits in page 1 while the first FD integer (offset 16) lands in page 2; `recvmsg` with MSG_PEEK (or flags 0). This is exactly the counterexample sequence: send → PEEK select → clone rights → header write OK → Install(fd7=fileA, entry 1) → Number copy FAILS → Report(len 0, CTRUNC) → return 1. A second layout faults the third integer instead (prefix case).

## Developer intent

Upstream commit 4d8078166e (PR asterinas#2176, Ruihan Li, 2025) introduced the order. The in-code comment at ctrl_msg.rs:199-201 says: "Perhaps we should remove the inserted files from the file table if we cannot write the file descriptor back to user space? However, even Linux cannot handle every corner case (scm.c#L357)." The cited Linux line covers a different corner (final-header `put_user` after delivery), not the per-FD install-before-publish ordering this finding flags; no PR reviewer raised the leak, and no test exercises a faulting control buffer. The message_header.rs:113-114 comment justifies the swallow ("no good way to report the errors to user space… silently ignore"), which concerns reporting, not the retained entry. Developer awareness of a suspicion is not a filed report, and the tracker search found none.

## Reproduction result

Test: `repro/test_bugMC-1_failed_number_install.c` (self-contained C; Level 0, pure black-box). A prior turn executed this but crashed during artifact validation and lost the source; this turn reconstructed it faithfully (semantics recovered from the surviving binary's disassembly), rebuilt the ISO (`osdk build --scheme scm-trace --release`, test as static init), and re-executed both runs.

Asterinas guest (pin 0c6053709 + harness instrumentation, QEMU/KVM, log `confirmation/MC-1/guest.log`):

```
MC1_SYSTEM {"sysname":"Linux","release":"5.13.0","machine":"x86_64"}
MC1_PROBE {"pred":7,"reused":1}
MC1_PEEK_FIRST_FAULT {"ret":1,"err":0,"reported_len":0,"ctrunc":1,"pred":7,"leaked":1,"new_fds":1,"leak_content":"AAAA"}
MC1_PEEK_RETRY {"delivered":4}
MC1_NOTE {"what":"ordinary first-fault also leaked"}
MC1_ORD_FIRST_FAULT {"ret":1,"err":0,"reported_len":0,"ctrunc":1,"pred":7,"leaked":1,"new_fds":1}
MC1_ORD_PREFIX_FAULT {"ret":1,"err":0,"reported_len":0,"ctrunc":1,"pred":7,"new_fds":3,"wrote_fd0":7,"wrote_fd1":8}
MC1_RESULT {"peek_leak":1,"ord_leak":1,"peek_retained":1,"prefix_installed":3,"prefix_published":2,"prefix_reported_len":0,"consistent":1,"invariant_matches_linux":0}
MC1_DONE 0
```

Linux control (host 7.2.8, same binary, `confirmation/MC-1/linux-control.log`): identical steps give `"leaked":0` in both fault cases, `prefix_reported_len:24`, `"invariant_matches_linux":1`.

The lines demonstrating the bug: `MC1_PEEK_FIRST_FAULT … "leaked":1 … "leak_content":"AAAA"` — fd 7 is open in the receiver's file table although `reported_len:0` claims no control data was delivered, and `pread(7)` returns file A's content, proving the entry aliases the message's first file; `MC1_ORD_PREFIX_FAULT … "new_fds":3,"wrote_fd0":7,"wrote_fd1":8` with `reported_len:0` — three installed versus two published and a misreported prefix (Linux: 24). This matches the MC final state (State 31: `fdTable[shared,7]=fileA`, `numberFailed={1}`, `numberComplete={}`, `reportedCtrunc=TRUE`, `returnValue=1`) and the same invariants.

Checklist before REPRODUCED:

1. **Level 0 or Level 1 alone?** Yes — Level 0. Only public syscalls (socketpair, sendmsg with SCM_RIGHTS, mmap/mprotect set up before the call, recvmsg, fcntl, pread). The fault is a deterministic page-granular address layout, not a race; no timing help, failpoints, or source patches.
2. N/A — no state injection or source patch was used.
3. **Real consumer observing the wrong outcome:** the `recvmsg` caller itself — after the syscall returns 1 with `msg_controllen=0`, `fcntl(pred, F_GETFD)` succeeds and `pread(pred)` returns "AAAA" (observer: `do_faulting_recv` in repro/test_bugMC-1_failed_number_install.c). In the prefix case the consumer additionally parses zero control data while its buffer holds two valid FD integers the kernel wrote.
4. **Permanent or masked?** Permanent for the process lifetime. The error is swallowed at message_header.rs:115, the syscall succeeds, temporaries are dropped, and no kernel path removes the installed entry; only process exit or the user guessing the unpublished number clears it. Each faulting call leaks one more fd (repeatable, enabling fd-table exhaustion). No masking mechanism exists, and the PEEK case leaves the message queued (retry delivered 4), matching the CE.

## Recommendation

Match Linux's ordering: reserve the lowest free fd number, copy the integer to user space, and only then install the file, releasing the reserved slot on copy failure (`put_unused_fd` equivalent). For the report path, count a partially delivered cmsg: when `k` FD integers were published before the fault, report the cmsghdr with `cmsg_len = CMSG_LEN(k*4)` and `msg_controllen = CMSG_SPACE(k*4)` alongside MSG_CTRUNC, so installed entries, complete integer writes, and the reported length describe one ownership outcome. Both changes stay within the no-whole-receive-rollback contract the scope requires.

---

## Entry 2: AST-36: Ordinary payload faults retain the datagram

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-2/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running cat /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json 2>/dev/null; echo "---"; ls /home/chin39/Documents/play/Spe...
running ls /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/ 2>/dev/nul...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output && cat confirmat...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/ 2>/de...
running find /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output -name "*MC-2*"...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
The previous incarnation of this turn completed Phase 1 and Phase 2 but failed pipeline validation on the `issue.json` proposal ("issues linked to model actions/invariants require model dependencies"), and the repro test source file is now missing from `repro/`. Let me verify the state of everything, then fix and re-execute properly.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/persistent-findings.md
running sed -n '340,470p' /home/chin39/Documents/play/Specula/src/specula/persistent_findings.py
Now let me check the worktrees, search for any surviving copy of the test source, and verify the counterexample log:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && grep -rl "MC2_RESULT" --inclu...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/output/vali...
The counterexample trace matches the finding exactly (Lock → Select → Copy → `payloadResult="Fault"`, `returnValue="EFAULT"`, `faultRetained=TRUE` → Unlock → Drop → Done with the message still queued). Let me check the head of the log for the invariant statement and inspect the worktrees:
running head -80 /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/outpu...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
The worktree situation is clear: `worktree-1` is the fresh git worktree for this turn (pin `0c6053709` + trace-only instrumentation, no warm `target/` yet); the old `worktree` is a stale remnant. Now let me verify the cited code in `worktree-1` (Phase 1 audit verification):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Code audit verified in `worktree-1`: upstream `try_recv` at pin `0c6053709` does `let len = writer.write(...)?;` — the `?` returns the fault to the caller *before* the `will_consume_data()` → `pop_front()` dequeue; the instrumented worktree keeps identical control flow (trace-only diff). Let me spot-check two call-chain links, then reconstruct the lost repro test from the surviving binary's debug info:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
The binary retains the exact output formats. Let me extract the test's own function structure from DWARF:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running grep -n "DW_AT_name : scenario\|DW_AT_name : main" /tmp/mc2_dwarf.txt | head; echo ---; awk '/DW_AT_name.*: scenario/{found=1} found{print; n++} n>60{exit}'...
running awk '/DW_AT_name.*: scenario/{found=1} found{print; n++} n>400{exit}' /tmp/mc2_dwarf.txt | grep -E "DW_AT_name|DW_AT_decl_line" | head -70
I have the full variable structure of the original test from DWARF. Before reconstructing, let me check whether the previous session's transcript (which would contain the exact original source) survives in pi's session storage:
running grep -rl "test_bugMC-2_payload_fault_retain" /home/chin39/.pi 2>/dev/null | head -5; echo "---"; grep -rl "MC2_SCENARIO" /home/chin39/.pi 2>/dev/null | head -5
The previous session's transcript survives. Let me extract the exact original test source from its `write` tool call:
running python3 - <<'EOF' import json path = "/home/chin39/.pi/agent/sessions/--home-chin39-Documents-play-Specula-runs-asterinas-unix-dgram-scm-rights-20261004T0643...
running python3 - <<'EOF' import json, re path = "/home/chin39/.pi/agent/sessions/--home-chin39-Documents-play-Specula-runs-asterinas-unix-dgram-scm-rights-20261004T...
The exact original test source is recovered (11,409 bytes, from the previous incarnation's `write` call). Now let me check the `source` tree's instrumentation state and how dependency roots resolve, before restoring the file and re-running:
running T=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; grep -n "let len = match result"...
running grep -n "_dependency_bytes" -A 40 /home/chin39/Documents/play/Specula/src/specula/persistent_findings.py | sed -n '1,50p'
`$T/source` is the instrumented tree and `worktree-1` is content-identical to it, so the issue.json source spans resolve correctly. Now let me read the recovered test source in full before restoring it:
reading /tmp/mc2_original_test.c
The recovered source is complete and self-consistent with the observed output formats (including the `MC2_LEAK` behavior: guest-as-init has no inherited fds, the host control prints its inherited fds). Now I'll restore the test file and prepare the re-run:
running cp /tmp/mc2_original_test.c /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specul...
running /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh; echo "threshold for kernel build: 10 GiB"; sudo...
Memory OK (47.86 GiB ≥ 10), Docker OK, test restored. Now update `run-repro.sh` for `worktree-1` (the assigned repo; content-identical to `$T/source`, so the warm step only syncs mtimes + copies the cargo caches) and preserve the previous binary for the byte-identity check:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-2/run-repro.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Now execute the full reproduction (blocking, with outer timeout):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
The reproduction re-ran successfully in this session — Asterinas retains the datagram after an ordinary EFAULT (`ordinary_fault_retained=1, invariant_matches_linux=0`), Linux consumes it (`retained=0, invariant_matches_linux=1`), PEEK retains in both. Now verify the restored source is byte-identical to what the previous incarnation compiled (proving provenance), and capture the full logs:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
Byte-identical binary (sha256 `02ae1824…`) — the restored source is provably the original, and the fresh outputs match the previous run exactly. Now fix the `issue.json` validation failure: add the required model dependencies (`root: "work"` selectors). First verify the source-span boundaries are unique in the source tree:
running T=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; cd $T/source && for pair in "ker...
`skip_some` is ambiguous (appears in both `MultiRead` and `MultiWrite`). Let me check the trait layout to pick a unique boundary:
running T=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; grep -n "trait MultiWrite" -A 30...
running T=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; grep -n "fn sum_lens\|Skips the...
Now rewrite `issue.json` with the corrected `iovec.rs` boundary and the required model dependencies:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-2/issue.json
running cd /home/chin39/Documents/play/Specula && PYTHONPATH=/home/chin39/Documents/play/Specula/src python3 - <<'EOF' from pathlib import Path from specula.persiste...
Validation passes. Now let me independently verify the Phase-1 developer-knowledge and novelty claims (git history + contracts + a fresh upstream tracker search) before finalizing:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running grep -n -B3 -A8 "AST-36" /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/contracts.md | head -60
Contracts confirm the prior-dataset mapping (SCM-13 = "existing AST-36" boundary control; "Recon analysis MC-2/T-3 is AST-36"). Let me check the dataset id-map for the exact citation, the MSG_PEEK commit's stated intent, and do a fresh upstream tracker check:
running grep -n -i "AST-36" /home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md 2>/dev/null | head -5; ls /home/chin39/Docum...
running curl -s --max-time 30 "https://api.github.com/search/issues?q=repo:asterinas-project/asterinas+recvmsg+EFAULT&per_page=10" | python3 -c "import json,sys; d=j...
running curl -s --max-time 30 -o /tmp/gh1.json "https://api.github.com/search/issues?q=repo:asterinas-project/asterinas+recvmsg+EFAULT&per_page=10"; curl -s --max-ti...
running head -c 300 /tmp/gh1.json; echo; echo "--- try web tool instead ---"
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running T=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights; grep -r "github.com" $T/source/....
using web_search
The upstream search confirms no issue/PR reports this mechanism at this site (nearest hit: vsock PR #3122 discusses EFAULT queue-retention for *vsock* — a different socket family). Now let me append the resume addendum to `investigation.md` and check the fresh build log:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-...
running grep -E "Finished .release|Compiling asterinas v" /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dg...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-2/investigation.md
running tail -8 /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmatio...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/MC-2/investigation.md
Final artifact-chain validation:
running cd /home/chin39/Documents/play/Specula && PYTHONPATH=/home/chin39/Documents/play/Specula/src python3 - <<'EOF' from pathlib import Path from specula.persiste...
# MC-2 Confirmation — AST-36: Ordinary payload faults retain the datagram

- **Source**: MC (real counterexample: `spec/output/validation-20261010T015405Z/MC_hunt_AST36.log` — trace re-verified directly this session: `MCSendBegin(message1, rights <<fileA,fileB,fileA,fileB>>)` → `MCRecvBegin(<<r1,1>>,"Recv","Full",FALSE)` → Lock → Select → Copy → `payloadResult="Fault"`, `returnValue="EFAULT"`, `faultRetained=TRUE` → Unlock → Drop → Done with `queue.msg="message1"`, `consumed=0`)
- **Novelty**: KNOWN (cite: Specula dataset `asterinas-bug-findings-2026-08`, id-map MC-2/T-3 → AST-36 "Analysis-only candidate"; fix-status: unfixed at pin 0c6053709 — the early return before dequeue is still present and the fresh guest run reproduces retention). Upstream tracker search (issues + PRs, three query shapes) found no report of this mechanism at this site; nearest hits are vsock PR #3122 (EFAULT queue-retention for a different socket family) and feature-gap tracking issues #2112/#1851.
- **Location**: `kernel/core/src/net/socket/unix/datagram/message.rs:291-299` (instrumented pin 0c6053709; upstream pin lines 195-202: `let len = writer.write(&mut VmReader::from(msg.bytes.as_slice()))?;` returns the fault before the `will_consume_data()` → `pop_front()` dequeue)

## Description

`MessageReceiver::try_recv` copies the datagram payload to the user buffer **before** dequeueing the message. When that copy faults (a payload page mapped `PROT_READ` write-faults mid-copy), the `?`/`Err` branch returns `EFAULT` while the message is still the queue front, so the datagram and its `SCM_RIGHTS` references stay queued. Linux's `__unix_dgram_recvmsg` unlinks the skb for an ordinary (non-PEEK) receive **before** the payload copy (`__skb_try_recv_from_queue` → `__skb_unlink`) and frees it on fault (`out_free: skb_free_datagram`), consuming the datagram and releasing its references. PEEK retains the message in both implementations. The result is an observable Linux-compatibility divergence: after an ordinary `recvmsg` fails with `EFAULT`, Asterinas re-delivers the same datagram (and its four `SCM_RIGHTS` FDs) on retry, where Linux returns `EAGAIN` with the message destroyed. References remain attributable (no leak: post-retry queue empty, FD scan clean), so the defect is the consumption-semantics divergence itself, not a reference imbalance.

## Trigger scenario

Level 0, public syscalls only: `socketpair(AF_UNIX, SOCK_DGRAM|SOCK_NONBLOCK)` → open two marker files A/B → `sendmsg` one nonempty datagram with `SCM_RIGHTS {A,B,A,B}` → `mmap` a page, `mprotect` it `PROT_READ` → ordinary `recvmsg` (flags 0) with the payload iovec pointing at that page and a valid writable control buffer → returns `-1/EFAULT` with the control buffer untouched and 0 FDs installed → retry `recvmsg` with a good buffer. On Asterinas the retry returns the same datagram and delivers 4 FDs naming A,B,A,B; on Linux the retry returns `-1/EAGAIN`. A faulting `MSG_PEEK` followed by an ordinary retry delivers in both (PEEK retains in both — the control). This maps 1:1 to the MC counterexample steps (`MCSendBegin` → `MCRecvBegin` with `payloadGood=FALSE` → `faultRetained=TRUE`).

## Developer intent

No commit message on the file's history states any intent about fault-consumption semantics: `fe1d4fe15` "Support UNIX datagram sockets" introduced copy-then-dequeue, `485f2189c` "Implement MSG_PEEK for UNIX datagram sockets" introduced `will_consume_data()` but kept the copy first (one-line commit body, no fault-semantics rationale), `e645c038d` removed a warn only. No comment near the site mentions EFAULT or Linux fault-path compatibility. Upstream tests exercise `recvmsg` EFAULT on UDP (`udp_err.c:390`) but never assert queue state afterwards, so nothing shows the developers chose or endorsed retain-on-fault for unix datagrams. The run's contracts file records this exact site as the known AST-36 boundary control ("A3 returns before normal dequeue on a payload fault… L3 unlinks a normal receive before payload copy and releases it on fault. Do not assume that every failed receive restores the message.") — a retained compatibility check, not a documented intended behavior.

## Reproduction result

Test: `repro/test_bugMC-2_payload_fault_retain.c` (self-contained C; runs as guest init on Asterinas and as the same-program host Linux control). Runner: `confirmation/MC-2/run-repro.sh` (this turn's `worktree-1`, pin 0c6053709 + trace-only instrumentation, warm cargo cache, Docker `asterinas/kernel-dev:0.18.1-20260926`, `osdk build --scheme scm-trace`, QEMU/KVM boot). Executed this session: `build_status=0`, `guest_status=33`, `linux_control_status=0`, run exit 0. (The first incarnation of this turn had run the same test; its source file was lost from `repro/` before the resume — I recovered the exact original from that session's transcript, and the recompiled binary is byte-identical, sha256 `02ae18247dbbe294c9aec111c0b1e7fd4a1fee1c3ad8c533e7994d6bc288fd1b`, proving the restored source is the one originally executed.)

Guest (Asterinas, real kernel boot, `/init`):
```
MC2_SYS {"sysname":"Linux","release":"5.13.0","machine":"x86_64"}
MC2_SCENARIO {"kind":"ordinary","fault":{"ret":-1,"errno":14},"control_touched":0,"fault_installed_fds":0,"retry":{"ret":1,"errno":0},"retained":1,"fds_delivered":4,"markers_ok":1,"post_retry_empty":1}
MC2_SCENARIO {"kind":"peek","fault":{"ret":-1,"errno":14},"control_touched":0,"fault_installed_fds":0,"retry":{"ret":1,"errno":0},"retained":1,"fds_delivered":4,"markers_ok":1,"post_retry_empty":1}
MC2_RESULT ordinary_fault_retained=1 peek_fault_retained=1 invariant_matches_linux=0 consistent=1
```

Host (Linux 7.2.8 control, same binary):
```
MC2_SYS {"sysname":"Linux","release":"7.2.8","machine":"x86_64"}
MC2_SCENARIO {"kind":"ordinary","fault":{"ret":-1,"errno":14},"control_touched":0,"fault_installed_fds":0,"retry":{"ret":-1,"errno":11},"retained":0,"fds_delivered":0,"markers_ok":0,"post_retry_empty":1}
MC2_SCENARIO {"kind":"peek","fault":{"ret":-1,"errno":14},"control_touched":0,"fault_installed_fds":0,"retry":{"ret":1,"errno":0},"retained":1,"fds_delivered":4,"markers_ok":1,"post_retry_empty":1}
MC2_RESULT ordinary_fault_retained=0 peek_fault_retained=1 invariant_matches_linux=1 consistent=1
MC2_LEAK fd=26
MC2_LEAK fd=30
```

The `MC2_LEAK` lines on the host are fds inherited from the invoking shell (informational; the guest-as-init scan is clean). The lines that demonstrate the bug: guest `MC2_SCENARIO "kind":"ordinary"` → `"retry":{"ret":1,...},"retained":1,"fds_delivered":4,"markers_ok":1` and `MC2_RESULT ordinary_fault_retained=1 invariant_matches_linux=0`, versus the Linux control's `"retry":{"ret":-1,"errno":11},"retained":0` and `invariant_matches_linux=1`. Expected (Linux) behavior after an ordinary EFAULT receive: the datagram is consumed, retry gets EAGAIN, the SCM_RIGHTS references are released undelivered. PEEK behaves identically in both (retained → delivered on retry), confirming the right bug and not an adjacent one.

## Recommendation

Make `try_recv` consume the datagram on a payload-copy fault for ordinary receives, matching Linux: unlink/dequeue the front message before (or on failure of) the payload copy, and on fault drop it, releasing its `AuxiliaryData` SCM_RIGHTS references without delivering them — e.g. pop the front message first, attempt the copy, and on `Err` drop the popped message (and its aux) before returning `EFAULT`; PEEK keeps the current retain-on-fault behavior. A minimal in-kernel test to add alongside: unix-dgram `recvmsg` EFAULT followed by a retry must observe `EAGAIN` (ordinary) and success (PEEK). Until fixed, document the divergence, since applications ported from Linux that retry after EFAULT will see messages reappear and receive FD deliveries Linux would have destroyed.

## REPRODUCED checklist

1. **Level 0 or Level 1 alone?** Yes — Level 0 alone triggered it: only public syscalls (`socketpair`, `open`, `write`, `sendmsg`, `mmap`, `mprotect`, `recvmsg`, `close`), no failpoints, no state injection, no source modification, no timing assistance; deterministic across both runs.
2. N/A — Level 2/3 were never used. (The injected pre-condition — a `PROT_READ` payload page — is itself produced by the real-API sequence `mmap` + `mprotect`, and corresponds to the admissible counterexample step `MCRecvBegin(..., payloadGood=FALSE)`.)
3. **Real consumer/caller:** the user-space receiver calling `recvmsg(2)` (kernel entry `sys_recvmsg`, `kernel/core/src/syscall/recvmsg.rs:15` → `UnixDatagramSocket::recvmsg`, `socket.rs:299` → `try_recv`). In the reproduction the consumer is the test process itself at its retry `recvmsg` (`repro/test_bugMC-2_payload_fault_retain.c`, scenario "Attempt 2"): it observes `ret=1` with 4 SCM_RIGHTS FDs delivered (markers A,B,A,B verified by `pread`) where Linux gives `-1/EAGAIN`. The consequence is observed live in the guest run, not argued-only.
4. **Permanent or masked?** Permanent until the application itself acts — no downstream mechanism reconciles it: no caller guard consumes the message after the fault, nothing re-delivers or discards it, and the queue mutex is simply dropped. The retained datagram persists until a later successful receive or socket close (which is exactly the harm: a message Linux destroyed remains receivable). Not a transient snapshot a safeguard fixes; no leak either (post-retry queue empty, guest FD scan clean, all references attributable to the queue while retained).

---

## Entry 3: Scenario 1: Captured object ownership survives descriptor reuse and release

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json
using ls
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/worktree/kernel/core/...
The worktree has modifications (instrumentation from the harness-validation phase). Let me examine them and the cited files.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The instrumentation is trace-only (per-thread buffer, no logic change). Let me check the harness infrastructure and existing build artifacts for reuse.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output && ls harness/ 2...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/harness && cat R...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/harness && ls sr...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && ls -la | head -20 && echo ===...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && git -C source rev-parse HEAD...
The `source` checkout has build artifacts from the successful harness attempt. Let me verify the worktree matches, then audit the cited code with exact line numbers.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && diff -r --brief source/kernel...
`worktree` ≡ `source` (identical diffs, identical trees), and `source/target/osdk` holds build artifacts from the successful harness attempt. Now let me look at the harness fixture skeleton (for the guest exit protocol) and the resource policy check.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/harness && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/harness && sed -...
The fixture exits via `reboot(RB_POWER_OFF)` as PID 1. Now let me check the resource policy state (memory gate, heavy lock, docker availability) before any build work.
running /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh; echo ====; ls -la /home/chin39/Documents/play/sp...
running sudo -n docker info 2>&1 | grep -E "Server Version|ERROR" | head -3; sudo -n docker image inspect asterinas/kernel-dev:0.18.1-20260926 --format '{{.Id}}' 2>&...
Environment is ready. Now **Phase 1: Investigation**. Let me audit the cited code with exact line numbers.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The citation line numbers may map to the pre-instrumentation file. Let me check the original.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Now let me check `get_file_fast!`/`into_owned` (the capture mechanism) and the datagram socket send/recv wrappers that own the temporary `AuxiliaryData`.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The ownership ledger audits clean so far. Now **Step 2: developer-knowledge search** — git history on these sites.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Git history shows no ownership-related fixes. Now the upstream tracker search (Step 3 / novelty check) — issues and recently merged/closed PRs.
using web_search
using fetch_content: List all issues (open and closed) that mention SCM_RIGHTS, file descriptor passing over unix sockets, descriptor lifetime, use-after-free or reference counting in the SCM_RIGHTS...
using fetch_content: List all closed and open pull requests touching the unix socket control message / SCM_RIGHTS file descriptor passing code (ctrl_msg.rs, scm, cmsg, file descriptor passing). For...
No prior report of this mechanism exists upstream — only the feature PR #2176 (whose known cycle-leak concern is a different, out-of-scope mechanism). Let me check the `scm-trace` OSDK scheme and qemu args used by the harness build.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && git -C source diff OSDK.toml...
Let me check the datagram buffer size constant (for the EAGAIN-fill case) and then write the Phase 1 record.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Now I'll write the Phase 1 investigation record.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/investigation.md
Now **Phase 2**: write the reproduction test. First a quick check of which socket APIs the validated harness fixture used (to stay on proven-supported ground).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/harness && grep...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
MSG_DONTWAIT is unsupported at this pin — the drain cases will use SOCK_NONBLOCK socketpairs (proven by the harness fixture). Let me verify pipe/pipe2 and fcntl(F_SETFL) support before writing the test.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Both supported. Writing the reproduction test now.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-1_ownership_conservati...
Now compile and run the Linux control (establishes expected behavior and validates the test itself).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && gcc -st...
NixOS host lacks static glibc — I'll build in the kernel-dev container (the proven recipe). First, fix two edge cases I spotted in the test (dup2 self-target in case 2, double close in case 9).
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-1_ownership_conservati...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && grep -n...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-1_ownership_conservati...
Now the runner script — builds the static binary (container gcc), runs the Linux control, packs a private initramfs, rebuilds the ISO from the pinned scheme (warm kernel target), boots the guest under KVM, and preserves the harness artifacts.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/repro-build/run-repro.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The runner exited suspiciously early. Let me inspect the evidence logs.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
9/10 PASS on the Linux control; case 10 unexpectedly returns -1 on Linux. Let me probe the errno to understand Linux's actual NULL-control semantics before adjusting the case.
running cat > /tmp/probe10.c <<'EOF' #define _GNU_SOURCE #include <errno.h> #include <stdio.h> #include <string.h> #include <sys/socket.h> #include <unistd.h> int ma...
running sed -i 's/#include <errno.h>/#include <errno.h>\n#include <fcntl.h>/' /tmp/probe10.c && gcc -O0 -o /tmp/probe10 /tmp/probe10.c && /tmp/probe10
Found it — my case 10 receives into a string literal (read-only) → EFAULT. A test bug, caught by the control run. Fixing with a writable buffer and errno reporting.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-1_ownership_conservati...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && grep -n...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-1_ownership_conservati...
The runner also has a bug: the container's `set -e` aborted when the control test exited 1 (its own failure), killing the whole script before stage 2. Fixing stage 1 to tolerate the test's exit code.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/repro-build/run-repro.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The guest run completed — only the artifact-restore `cp` failed (root-owned target dir). Let me check the guest log.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
**All 10 cases PASS on the Asterinas guest** (`CR1_DONE 0`), matching the Linux control. Before settling the verdict, one more angle deserves a real probe: the *racing* sender-close-vs-capture (a timing dimension my sequential cases don't cover). Adding a Level-1 concurrency case, then re-running.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-1_ownership_conservati...
Now fix the runner's restore step (root-owned target dir needs a container-side copy).
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/repro-build/run-repro.sh
The earlier failed restore means the harness ISO may already be overwritten by my initramfs build. Let me check the current state against the harness's recorded hashes.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && sha256sum source/target/osdk/...
One `sha256sum` call was briefly blocked by the auto-mode classifier timing out; the retry executed normally. Continuing the state check.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && cat .specula-output/harness/e...
The harness's live ISO/ELF were overwritten by my rebuild. Let me check whether the harness evidence archived copies, and whether its initramfs is still intact for a content-equivalent restore.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/harness && ls -l...
Harness initramfs and fixture are intact. Updating the runner: backup before build, and a final stage that restores the harness-content ISO from its own initramfs.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/repro-build/run-repro.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
All 11 cases PASS on the guest, including the racing close-vs-capture (32,768 delivered fds, all naming the captured object). Let me verify the full evidence trail (control run, build exits, harness restore).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Full evidence trail is clean: Linux control 11/11 PASS, guest 11/11 PASS (`CR1_DONE 0`), harness-content ISO restored (stage-4 exit 0). Now let me record the Phase 2 outcome in the investigation file.
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-1/investigation.md
Phase 1 and Phase 2 are complete. All evidence is recorded in `confirmation/CR-1/investigation.md`, `confirmation/CR-1/repro-build/evidence/`, and the executed test at `repro/test_bugCR-1_ownership_conservation.c`.

---

- **Source**: Code Review (the five `MC_hunt_scenario1*` configurations returned no violation — three exhaustive rows clean, two budget rows no reported violation — so this is code-review-sourced per the skill's rule; counterexample: null)
- **Novelty**: NEW (searched upstream issues and merged/closed PRs on 2026-10-10: only PR #2176, the original SCM_RIGHTS feature, whose cycle-leak discussion is a different mechanism — socket-object cycles, excluded from this run's scope; no issue/PR/CVE reports an ordinary-file ownership-accounting break at these sites)
- **Location**: kernel/core/src/net/socket/unix/ctrl_msg.rs:109 (capture), with the audited pipeline spanning ctrl_msg.rs:139-148, 222-240, 304-310; net/socket/unix/datagram/message.rs:83, 268; fs/file/file_table.rs:190-206; syscall/close.rs:22-35

## Description

The finding hypothesized an ownership-accounting break in the AF_UNIX SOCK_DGRAM SCM_RIGHTS pipeline: a captured file reference either vanishing (premature drop → a delivered fd naming a freed/recycled object) or gaining an unexplained owner (leak → an object never released) across capture, enqueue move, PEEK clone, ordinary-receive move, installation clone, temporary release, FD removal/drop, or final queue disposal. The code audit found no candidate site: `get_file_fast!(..).into_owned()` (ctrl_msg.rs:109) always takes a new owned `Arc` clone (the fd number is never stored); every hand-off is a Rust move (`files.append`, `mem::take` ×2) or an owner-attributed clone (`files.clone()` for PEEK, `file.clone()` for installation); every failure path releases exactly what it captured via RAII; queue disposal (`*inner.lock() = None`) drops each queued reference exactly once. Live reproduction confirmed the contract: all eleven black-box probes passed on the real Asterinas kernel, matching the Linux control and the independent harness trace audit ("Both ordinary objects finish with no modeled owner after cleanup"). The hypothesized defect does not exist.

## Trigger scenario

Eleven Level-0 public-API sequences over `socketpair(AF_UNIX, SOCK_DGRAM|SOCK_NONBLOCK)` driving every transition in the hypothesized defect class: send SCM_RIGHTS then close the sender fd; send then force a different file onto the sender's old number via `dup2`; PEEK-clone then ordinary receive (consume-once, both naming the captured object); duplicate fds in one message; queue disposal without receiving (pipe write-end must reach EOF); full receive cycle then close (EOF); disposal of eight queued messages then a liveness round-trip; cross-process capture/install with the sender exiting while the message is queued; queue-fill to EAGAIN (temporary capture released) then full drain (EOF); receive with NULL control buffer (refs released, EOF); and a Level-1 timing probe — 40 rounds of a sender thread racing a closing thread on the same fd (32,768 successful racing deliveries, every one naming the captured object).

## Developer intent

No commit message in the history of `ctrl_msg.rs` / `datagram/message.rs` describes an ownership or lifetime fix; the pipeline arrived as feature work (`4d8078166`, `c3572e954`, `e0b702663`). Near-site commentary records a different mechanism: the FIXME about UNIX-socket reference cycles (Linux's garbage-collection gap, mitigated by the CAP_SYS_ADMIN check), explicitly out of this run's scope, plus TODOs for ETOOMANYREFS limits and the Linux-matching corner-case note at ctrl_msg.rs:145-147. Neither is the ordinary-file ownership mechanism hypothesized here. No existing test asserts broken-ownership behavior.

## Reproduction result

Test: `.specula-output/repro/test_bugCR-1_ownership_conservation.c`, executed via `confirmation/CR-1/repro-build/run-repro.sh` (static build in the pinned kernel-dev container, ISO rebuilt from the `scm-trace` scheme with the test as initramfs `/init`, QEMU/KVM boot with the harness's guest shape, harness-content ISO restored afterwards; exits: build 0, guest 33, restore 0).

Linux control (`evidence/linux-control.log`):
```
CR1_CASE 1 send-close-recv-identity PASS delivered fd 5 names sender file
CR1_CASE 2 fd-number-reuse-after-send PASS delivered fd names captured file, not reused number 5
CR1_CASE 3 peek-clone-then-recv PASS peek fd 5 and recv fd 6 both name captured file; queue empty after
CR1_CASE 4 duplicate-fds-one-message PASS recv r=3 got=3 mapping_ok=1
CR1_CASE 5 disposal-releases-queued-ref PASS read end saw EOF after queue disposal
CR1_CASE 6 recv-cycle-releases-ref PASS recv r=3 got=1 eof=1
CR1_CASE 7 disposal-liveness PASS kernel alive and correct after disposal
CR1_CASE 8 cross-process-tables PASS delivered fd names child's object ino=7841194 after child exit
CR1_CASE 9 eagain-temporary-release PASS sent=93 drained=93 eof=1
CR1_CASE 10 null-control-releases-refs PASS recv=3 errno=0 flags=0x8 eof=1
CR1_CASE 11 racing-close-vs-capture PASS rounds_ok=1 bad=0 delivered=278
CR1_DONE 0
```

Asterinas guest, pinned commit `0c6053709` (`evidence/guest.log`):
```
CR1_CASE 1 send-close-recv-identity PASS delivered fd 5 names sender file
CR1_CASE 2 fd-number-reuse-after-send PASS delivered fd names captured file, not reused number 5
CR1_CASE 3 peek-clone-then-recv PASS peek fd 5 and recv fd 6 both name captured file; queue empty after
CR1_CASE 4 duplicate-fds-one-message PASS recv r=3 got=3 mapping_ok=1
CR1_CASE 5 disposal-releases-queued-ref PASS read end saw EOF after queue disposal
CR1_CASE 6 recv-cycle-releases-ref PASS recv r=3 got=1 eof=1
CR1_CASE 7 disposal-liveness PASS kernel alive and correct after disposal
CR1_CASE 8 cross-process-tables PASS delivered fd names child's object ino=8 after child exit
CR1_CASE 9 eagain-temporary-release PASS sent=65 drained=65 eof=1
CR1_CASE 10 null-control-releases-refs PASS recv=3 errno=0 flags=0x8 eof=1
CR1_CASE 11 racing-close-vs-capture PASS rounds_ok=1 bad=0 delivered=32768
CR1_DONE 0
```

No live harm manifested: every delivered fd named the captured object (never the reused number, never a freed object), messages consumed exactly once, and the pipe write-end reached EOF on every release path — disposal, receive-cycle, EAGAIN temporary release, and NULL-control — including under the racing close (case 9's count of 65 matches the kernel's 64 KiB `UNIX_DATAGRAM_DEFAULT_BUF_SIZE` exactly). Levels 2 and 3 do not apply: every hypothesized pre-condition is naturally reachable and was reached through real API sequences, and patching or injecting a broken refcount would fabricate the symptom rather than reveal it. The escalation ladder is exhausted with the contract intact.

## Recommendation

No fix needed — close as not-a-defect. The executed bounds (three exhaustive MC rows, the 23-fixture harness trace audit, and these eleven live probes spanning every enumerated transition) establish the ownership-conservation contract for ordinary-file references in this pipeline. Two adjacent gaps remain tracked elsewhere and out of scope here: the AST-32 installation-before-publication corner (a separate finding) and the known UNIX-socket-cycle leak (upstream PR #2176 discussion, guarded by the CAP_SYS_ADMIN check). If future work touches `FileMessage`/`AuxiliaryData`, the reproduction test is reusable as a regression guard (`gcc -static … repro/test_bugCR-1_ownership_conservation.c`).

---

## Entry 4: Scenario 2: Queue selection and ancillary completion have different orders

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/debate.md

Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/pi-slopchop/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @earendil-works/pi-tui. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-subagents/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: @sinclair/typebox, typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
Warning: Extension package "/home/chin39/.pi/agent/npm/node_modules/@tintinweb/pi-tasks/package.json": Host-provided extension packages must be declared in peerDependencies with a "*" range, not dependencies: typebox. Installed copies can bypass the extension loader and create duplicate runtime modules.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
running ls -la /home/chin39/Documents/play/Specula/skills/bug-confirmation/
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
I'll start by reading the skill (done) and now execute Phase 1: Investigation. Let me set up task tracking and explore the target code.
using TaskCreate: Read message.rs:179-217, ctrl_msg.rs:141-148, ctrl_msg.rs:304-310, recvmsg.rs:32-52; trace call chain; record trigger scenario and safeguards into investigation.md
using TaskCreate: git log/blame on cited sites, comments, tests; search upstream issue tracker and PRs for this mechanism; decide DROPPED pre-filter or proceed
using TaskCreate: Write repro/test_bugCR-2_*, execute with timeout, walk Level 0→3 escalation, capture output
using TaskUpdate
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
The cited `try_recv` is now clear: selection, payload copy, dequeue, and `generate_control` all happen under the queue mutex; the lock is dropped before the caller publishes FDs. Now let me read the cited `ctrl_msg.rs` regions.
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
I've now read the full `ctrl_msg.rs`. Key facts so far: `generate_control` (the ownership transfer — `mem::take` for Recv, `files.clone()` for Peek) runs **inside** the queue mutex within `try_recv`; only `FileMessage::write_to` (file-table insert + fd-number write) runs after lock release. Now the cited `recvmsg.rs:32-52`:
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
The publication path is confirmed: `sys_recvmsg` → `socket.recvmsg` (queue-mutex-protected select/consume/generate_control) → drop borrow → `write_control_messages_to_user` (file-table insert + fd-number copy, after queue lock release). Now let me trace the intermediate layers: the datagram `recvmsg` wrapper and `write_control_messages_to_user`.
using ffgrep
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
The full call chain is established. Let me check the remaining links: `block_on` (retry semantics), `receive_behavior` (flag mapping), and the file-table `insert` used during publication.
using ffgrep
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
Now let me check the worktree's git state — the pin commit and what the trace instrumentation modified (provenance matters for reproduction).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The worktree adds an `scm_trace` instrumentation layer plus a regression test `scm_rights_trace.c` on top of pin `0c6053709`. Let me verify the instrumentation is trace-only (no logic change) in the cited files, since reproduction must run at the pinned source semantics.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
`message.rs` diff is trace-only; critically, `generate_control` was already inside the queue-mutex scope in the pinned source (the explicit `drop(guard)` replaced the implicit end-of-scope drop). Let me verify `ctrl_msg.rs` and `file_table.rs` diffs are likewise trace-only.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The pinned-source semantics are preserved (trace-only diff; `mem::take`/`files.clone()` ownership split unchanged). Now let me look at the existing test harness and the resource policy before planning reproduction.
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/test/initram...
reading /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/resources.json
Resource policy noted: as a phase worker I follow the limits (2 CPUs, guest ≥2 SMP, 2G guest memory, check effective memory before kernel build) without reacquiring the heavy lock. Let me read the rest of the harness test to understand the runner.
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/test/initram...
This harness already implements the exact CR-2 competition scenario (case 18: PEEK vs ordinary receive racing on one datagram with SCM_RIGHTS; case 17: two competing ordinary receivers). Let me check what the `prctl` control interface (`scm_trace.rs`) does, since the repro may use it.
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
The instrumentation is purely observational (records + dumps, no fault injection or delays). Now let me check how previous rounds built/ran the kernel test — looking at the spec-output tree and existing repro artifacts.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output && ls -la; echo...
Existing repro tests live in `repro/` and a `harness/` dir exists. Per the skill's reuse policy, let me inspect the harness and build logs for a known-successful run recipe (not the findings themselves).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output && ls -R harness...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output && cat harness/r...
The harness has a known-good Docker+QEMU recipe. Let me check for reusable build artifacts (prebuilt ISO, initramfs, linux-control) and the guest-build script.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && ls source/ 2>/dev/null | head...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && cat .specula-output/bug-confi...
`source` (used for the prebuilt ISO) and my worktree share the same pin and instrumentation. The harness recipe: gcc-static test → initramfs → `osdk build` in Docker → QEMU/KVM boot. Let me verify the environment (docker, KVM, memory) before committing to that path.
running sudo -n docker -H unix:///var/run/docker.sock info --format '{{.ServerVersion}} kvm={{.Devices.KVM}}' 2>&1 | head -3; ls -l /dev/kvm 2>&1; bash /home/chin39/...
Environment is ready (docker 29.8.1, /dev/kvm, 39.65 GiB effective mem ≥ 10 GiB build threshold). Continuing Phase 1: developer-knowledge search — git history on the cited sites.
using TaskUpdate
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The key commit is `485f2189c` (MSG_PEEK for UNIX datagram). Let me examine it for stated intent about the clone-vs-take design.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The MSG_PEEK commit restructured `try_recv` so both consume (`pop_front`) and peek (`front_mut`) call `generate_control` inside the queue mutex — the ownership-transfer-under-lock design. Let me check the test it added and any existing concurrent-receive tests.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Upstream has only single-threaded MSG_PEEK tests; the sole concurrent SCM_RIGHTS test is the Specula harness. Now the known-status search (issue tracker + recent PRs for this mechanism):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
using web_enable
using web_search
The Linux MSG_PEEK×GC race is a different site/mechanism (Linux unix GC vs peek refcount; Asterinas has no SCM GC). Let me search the asterinas tracker more specifically for this mechanism.
using web_search
No asterinas tracker report matches this mechanism. One last known-status check: recent upstream commits touching the cited files (a fix landed days ago still makes it KNOWN).
using fetch_content: List the commits shown on this page: for each, give the commit title, author, and commit date. I'm looking for any commit made after October 2026 or any commit mentioning SCM_RI...
using fetch_content: List all commits shown on this page for this file's history: commit titles, and dates if visible. I want to know whether any commit after 2026-10-04 touches this file, especiall...
Upstream shows no post-pin fix at these sites → Novelty: **NEW**. Let me finish the code audit with the file-table insert locking, then write `investigation.md`.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/worktree/kernel/core/...
FileTable is inside an `RwArc` — concurrent inserts serialize under its write lock. The code audit is complete. Let me check build-cache sizes and worktree/source equivalence for provenance-safe reuse.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && du -sh source/target 2>/dev/n...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights && diff -rq --no-dereference sou...
Worktree ≡ `source` (only `.git`/`target` differ) — the prebuilt kernel cache is provenance-compatible. Quick check whether `sched_setaffinity`/`getcpu` exist on Asterinas (affects race synchronization design):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
`sched_setaffinity`/`getcpu` are implemented. Now writing the Phase 1 evidence record:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/investigation.md
using TaskUpdate
Phase 1 is recorded. Now Phase 2 — writing the reproduction test targeting the CR-2 mechanism:
using TaskUpdate
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
The first draft has several bugs I must fix before compiling (pthread error-code semantics, V2's T1-must-consume flag, array bounds in accounting, delay-sweep asymmetry). Rewriting:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
Fixing a leftover editing artifact in `fd_ok`:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
Continuing Phase 2: compile the test (quick host syntax check first, then the Docker-based build per the known-good recipe).
running which gcc cc clang 2>/dev/null; gcc --version 2>/dev/null | head -1
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
Missing `sys/syscall.h` include (the harness had it). Fixing:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
Clean compile. Running the Linux control on the host (this validates both the test and the expected Linux semantics):
running cd /tmp && timeout 120 ./cr2_host_check; echo "exit=$?"
Linux control passes with 0 failures — but `same_cpu=240` says pinning failed (threads ended up on the same CPU). Let me probe why:
running cat > /tmp/pinprobe.c <<'EOF' #define _GNU_SOURCE #include <sched.h> #include <stdio.h> #include <pthread.h> #include <sys/syscall.h> #include <unistd.h> sta...
Found it — `run_pair` never sets `j2->tid = 2` (memset leaves 0 → `cpu_of[-1]` out-of-bounds write, no pinning for T2, and tid 0 would collide with main's trace registration). Fixing:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
Linux control is clean: 0 failures across all variants, 120/240 V1 rounds hit the both-delivered interleaving, workers always on distinct CPUs. Now the Asterinas guest build + boot, mirroring the known-good harness recipe (with the harness ISO backed up first):
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/build_and_run.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The build phase succeeded but I passed the host path to QEMU instead of the container path (`/work/...`). Checking build state and fixing:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/source/target/osdk/ | head;...
ISO built (15:28, fresh, kernel reused from cache). Fixing the QEMU path to the container mount and re-running the boot only:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/build_and_run.sh
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/boot_only.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The Asterinas guest passes Level 0 cleanly: **CR2_DONE 0** across 600 rounds (V1 hit the peek+recv both-delivered interleaving 16 times; V2 at-most-once held 160/160). But `instrumented=0` — Asterinas reports sysname "Linux", and I omitted the harness's `#ifdef SCM_ASTERINAS` override, so no trace dumps happened. Fixing to capture interleaving evidence:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
A kernel panic this run! Let me examine the full guest log — this needs careful diagnosis (could be the hunted bug, the instrumentation, or the trace interface).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
reading /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/guest.log
The panic is at `scm_trace.rs:180` — my `round_cleanup()` calls the dump `ctl(3)` unconditionally, but on non-instrumented rounds no trace buffer was registered (`take().unwrap()` on None). This is a test-harness misuse of the trace interface, not the hunted bug. Fixing:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
Declaration order issue — `main_trace_on` must be declared with the globals before `fixture`:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
Host still clean. Rebuilding the guest and booting again:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Panic again — checking how far it got this time:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Root cause found: the trace-register command (`ctl(0)`) captures object pointers from **open fds** — but my fixture closes the object fds before the workers register, so registration fails with EBADF (leaving no buffer), and the worker's dump then panics. The harness avoided this by registering while fds were still open. Restructuring fixture/send ordering:
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Instrumented Asterinas run: **CR2_DONE 0 failures** — 74/240 V1 rounds hit the peek+recv both-delivered interleaving, V2 160/160 at-most-once, workers always on distinct CPUs. Now the post-hoc trace analysis to prove the hypothesized interleaving actually occurred:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/analyze_interleave.py
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The trace analysis **proves the hypothesized interleaving is real**: in 8 of 12 instrumented rounds, the peek selected the message before the recv dequeued it, yet published its file-table inserts *after* the dequeue (overlapping the recv's own publication phase) — and all properties held in every such round. 

Level 0 passed with timing assistance (pinning + offset sweep). Per the ladder, I'll escalate Level 1 further: widen the post-lock publication window 4× with 8 rights per message (harder timing surface, same logic):
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro/test_bugCR-2_peek_consume_interle...
editing /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-2/build_and_run.sh
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/repro && timeout...
8-rights escalation passes on Linux. Running it on Asterinas (Level 1 escalation — 4× wider publication window):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
The 8-rights escalation also shows trace-proven publication-after-consumption (5/12 rounds) with zero violations. The r8 run overwrote the default-rights guest log, so let me regenerate and preserve both evidence logs:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Both evidence logs preserved. Final verification of the evidence, restore the harness ISO I backed up, and tidy up:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Path arithmetic error — `confirmation/CR-2` needs `../../../source`. Restoring correctly:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation/CR-...
Harness ISO restored to its pre-work state. Appending the Phase-2 record to the investigation file:
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/confirmation...
using TaskUpdate
All phases complete. Final report:

---

## CR-2 Confirmation Report

- **Source**: Code Review (MC_hunt_scenario2* returned no violation; not MC-found)
- **Novelty**: NEW (searched asterinas GitHub issues + recently merged/closed PRs + upstream commit lists for both cited files — latest upstream commits are `819e7a826`/`b9cfb5ccf` (Aug 2026, refactor/visibility), no report of this mechanism at this site; Linux's af_unix GC-vs-PEEK bugs are a different site/mechanism — Asterinas has no SCM GC)
- **Location**: `kernel/core/src/net/socket/unix/datagram/message.rs:179-217` (pinned; `try_recv`), `kernel/core/src/net/socket/unix/ctrl_msg.rs:141-148` (`FileMessage::write_to`), `ctrl_msg.rs:304-310` (`generate_control`), `kernel/core/src/syscall/recvmsg.rs:32-52`

### Description

The finding's core observation is **real**: queue selection/consumption and ancillary FD publication do have different orders — selection, `pop_front`, and the SCM_RIGHTS ownership transfer (`mem::take` for Recv, `files.clone()` for Peek) run under the queue mutex in `try_recv`, while file-table insertion and fd-number copying run after the lock is released in `sys_recvmsg` → `FileMessage::write_to`. But the hypothesized defect classes are structurally impossible at the pinned source: the ownership-critical section is inside the lock, and the post-lock publication phase touches only per-call state (each thread's own `Vec<Arc>` clones, its own user control buffer) plus the file table, which has its own write lock (`RwArc<FileTable>`). No shared mutable ownership state crosses the lock boundary, so an earlier PEEK's publication interleaving with a later ordinary receive cannot double-consume, deliver moved rights, or publish stale rights. Peek-clone fds published after consumption name the still-live captured objects — exactly Linux's MSG_PEEK + SCM_RIGHTS duplication semantics.

### Trigger scenario

Two threads of one process on an AF_UNIX SOCK_DGRAM socket whose queue holds one datagram with SCM_RIGHTS to two marker files ('A'/'B'); sender closes its copies so the queue owns the only references. Thread P does `recvmsg(MSG_PEEK)`, thread R does `recvmsg(0)`, pinned to distinct CPUs with swept relative start offsets. When P's selection precedes R's dequeue, both deliver: P publishes cloned refs, R publishes the moved refs — P's publication can land after R's dequeue, overlapping R's publication phase.

### Developer intent

Commit `485f2189c` ("Implement MSG_PEEK for UNIX datagram sockets", 2026-06-09) restructured `try_recv` so **both** the `pop_front` and `front_mut` branches call `generate_control` inside the queue mutex — the ownership-transfer-under-lock design is deliberate structure, though the commit message carries no concurrency commentary. The `write_to` comment ("Perhaps we should remove the inserted files… even Linux cannot handle every corner case") concerns install-before-number-copy (Scenario 3), not this interleaving. Upstream tests cover only single-threaded MSG_PEEK; no developer commentary addresses the interleaving.

### Reproduction result

Test: `.specula-output/repro/test_bugCR-2_peek_consume_interleave.c` — executed on the pinned Asterinas kernel (QEMU/KVM, 2 CPUs; ISO rebuilt from the provenance-verified cache, worktree ≡ `source` at pin `0c6053709`) and on Linux as control. 600 rounds/run: V0 sequential, V1 PEEK-vs-recv race, V2 recv-vs-recv, V3 peek-storm, V4 multi-message.

**Asterinas, default build** (`guest_r2.log`):
```
CR2_SYS {"sysname":"Linux","release":"5.13.0","instrumented":1}
CR2_VARIANT V0 rounds=20
CR2_VARIANT V1 rounds=240 both_delivered=38 recv_only=202 same_cpu=0
CR2_VARIANT V2 rounds=160 exactly_one=160
CR2_VARIANT V3 rounds=120
CR2_VARIANT V4 rounds=60
CR2_DONE 0 (failures=0 trace_warns=0 seconds=13)
```
**Asterinas, 8-rights escalation (4× wider publication window)** (`guest_r8.log`): `CR2_DONE 0 (failures=0 …)`, V1 `both_delivered=61`, V2 `exactly_one=160`. A third instrumented run: `both_delivered=74`. Total 173 both-delivered rounds, 0 `CR2_FAIL` lines anywhere.

**Linux control** (same binary, host kernel): `CR2_DONE 0`, V1 `both_delivered=109`, V2 `exactly_one=160` — identical outcomes.

**Interleaving proof** (`analyze_interleave.py` over the trace dumps):
```
instrumented_v1_rounds_with_select+dequeue = 12
peek_selected_before_consume_and_published_after_consume = 4   [r2 run; 5 in r8; 8 in run 1]
  case=1000 peek_select=223147 recv_dequeue=268784 peek_last_insert_end=296387 recv_complete=365680
```
The kernel trace timestamps prove the hypothesized interleaving **actually occurred**: the peek selected the message before the recv dequeued it, and its `FileTableInsert` publication finished after the dequeue, overlapping the recv's publication phase — while every property held (markers correct via `pread` on every delivered fd, exactly-once consumption verified by follow-up EAGAIN, exact fd-set accounting, no MSG_CTRUNC).

**Escalation ladder**: Level 0 exhausted (real API, 600 rounds × multiple runs, both kernels); Level 1 exhausted (CPU pinning asserted, offset sweeps, 4× wider window — interleaving triggered and trace-proven); Level 2 unsound (each defect class needs a pre-condition no real-API sequence can produce — the moved Vec and the pop are under the queue mutex — injecting it would fabricate the bug); Level 3 inapplicable (a delay only widens an already-exercised interleaving; no shared mutable state exists to corrupt). REPRODUCED is not claimed: no real consumer observed a wrong outcome in any of the 173+ interleaving rounds; the wrong state never forms, so there is also no mask (nothing downstream fixes a state that is never wrong) and no env limit (the mechanism itself was triggered here).

### Recommendation

Close as not-a-bug. The design already places the ownership transfer inside the queue mutex, which is precisely what makes the ordering difference benign. If future work moves any part of the ownership transfer (clone/take) or queue mutation outside the queue mutex, this scenario's properties (at-most-once consumption, peek-delivers-valid-copies, no publication of stale rights) are the regression surface — the committed repro test and the harness's competition cases 17/18 cover them.

---
