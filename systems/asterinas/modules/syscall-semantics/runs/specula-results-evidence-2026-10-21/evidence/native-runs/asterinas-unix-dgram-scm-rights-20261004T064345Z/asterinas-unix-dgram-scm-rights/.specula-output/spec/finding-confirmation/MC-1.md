# MC-1

Status: REPRODUCED
Run: asterinas-unix-dgram-scm-rights-20261004T064345Z

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
