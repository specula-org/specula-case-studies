# Confirmation Report — asterinas-syscall-regular-file-partial-progress

## Final Result

Reproduced bugs: 6 = 4 NEW + 2 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 1
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 8
Dispositions: 8 total = 6 reproduced + 0 env-limited + 1 masked + 1 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | MASKED | no |
| 7 | MC-7 | REPRODUCED | yes |
| 8 | CR-1 | FALSE POSITIVE | no |

## Entry 1: A positive read prefix is exposed but returned as EFAULT

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-1/debate.md

I'll start by reading the bug-confirmation skill in full, then investigate.
running find /home/chin39/.claude -type d -name "bug-confirmation" 2>/dev/null; echo "---"; find / -type d -name "bug-confirmation" -not -path "*/node_modules/*" 2>/...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running ls -d /home/chin39/.claude/skills/*/ 2>/dev/null | head -50; echo "---PLUGINS---"; ls -d /home/chin39/.claude/plugins/*/ 2>/dev/null | head -30
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running ls -d /home/chin39/.claude/skills/*/ 2>/dev/null | tail -30
running cat /tmp/claude-1000/-home-chin39-Documents-play-Specula-runs-asterinas-syscall-regular-file-partial-progress-20260823T030315Z-asterinas-syscall-regular-file...
running find /home/chin39/Documents/play/Specula -maxdepth 4 -type d -name "*bug-confirmation*" 2>/dev/null; echo "---"; ls /home/chin39/Documents/play/Specula/ 2>/d...
running find /home/chin39/Documents/play/Specula/skills/bug-confirmation -type f | sort; echo "=== guide.md ==="; cat /home/chin39/Documents/play/Specula/skills/bug-...
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md; echo "=========== 01-investigation.md ==========="; cat /home/chin39/Documents/play...
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
Skill read in full. Starting Phase 1 investigation.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now the code audit. Let me read the cited sites.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running docker images 2>&1 | head -20; echo "=== KVM ==="; ls -la /dev/kvm 2>&1; echo "=== nproc ==="; nproc
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running which gh && gh auth status 2>&1 | head -5
running cd /tmp && timeout 120 gh search issues --repo asterinas/asterinas "partial read EFAULT" --limit 20 --json number,title,state,url 2>&1 | head -60
running cd /tmp && timeout 120 gh search issues --repo asterinas/asterinas "read_fallible" --limit 20 --json number,title,state,url 2>&1 | head -60; echo "=== prs ==...
running cd /tmp && for q in "partial copy fault short read" "EFAULT short read" "page fault user buffer partial" "short read semantics" "read returns EFAULT partial"...
running cd /tmp && for q in "EFAULT" "partial write" "short read" "VmWriter" "copied_len"; do echo "### $q"; timeout 90 gh search issues --repo asterinas/asterinas "...
running cd /tmp && timeout 120 gh issue view 711 --repo asterinas/asterinas --json number,title,state,url,createdAt,closedAt,body,comments --jq '{number,title,state,...
running cd /tmp && echo "### PRs mentioning 711"; timeout 120 gh search prs --repo asterinas/asterinas "711 EFAULT" --limit 15 --json number,title,state,url --jq '.[...
running cd /tmp && timeout 120 gh issue view 3181 --repo asterinas/asterinas --json number,title,state,url,body --jq '"\(.number) [\(.state)] \(.title)\n\(.url)\n---...
running cd /tmp && timeout 120 gh api "repos/asterinas/asterinas/issues/711/timeline?per_page=100" --jq '.[] | select(.event=="cross-referenced" or .event=="referenc...
running cd /tmp && timeout 120 gh api "search/commits?q=repo:asterinas/asterinas+EFAULT+partial&per_page=20" -H "Accept: application/vnd.github.cloak-preview" --jq '...
running cd /tmp && timeout 90 gh api "repos/asterinas/asterinas/contents/kernel/core/src/error.rs?ref=main" --jq '.content' 2>/dev/null | base64 -d | grep -n -A5 "Fr...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now setting up the reproduction environment with a pristine (uninstrumented) kernel.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running mkdir -p /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-pro...
running cd /tmp && gcc -Wall -Werror -O2 -o /tmp/mc1_repro /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/...
running cd /tmp && timeout 120 /tmp/mc1_repro /tmp/mc1-linux-tmpfs /home/chin39/mc1-linux-disk 2>&1 | tee /tmp/mc1_linux_control.txt; echo "EXIT=$?"; echo "=== host...
running set -eu W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-pr...
running ls -d ${XDG_CACHE_HOME:-/tmp}/specula-asterinas-regular-file 2>/dev/null && du -sh ${XDG_CACHE_HOME:-/tmp}/specula-asterinas-regular-file/* 2>/dev/null; echo...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress;...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress l...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress t...
Now the driver script that builds and boots Asterinas:
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running L=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Reproduced at escalation Level 0 on a pristine kernel. Verdict below.

---

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/asterinas/asterinas/issues/711; fix-status: unfixed)
- **Location**: `kernel/core/src/error.rs:209`

## Description

A fallible user copy reports its partial progress as a tuple — `ostd/src/mm/io/mod.rs:355-358` advances `writer.cursor` by `copied_len` (the user buffer is already overwritten) and then returns `Err((Error::PageFault, copied_len))`. `impl From<(ostd::Error, usize)> for Error` at `kernel/core/src/error.rs:209-214` throws the `usize` away and yields a scalar `EFAULT`. Every layer above therefore has no count to work with: `Vmo::read` (`kernel/core/src/vm/page_cache/vmo/mod.rs:557`) propagates with `?`, the backend discards its own `read_len` (`ext2/inode/file.rs:241`, `ramfs/fs.rs:709`), `InodeHandle::read` returns before `*offset += len` (`fs/file/inode_handle.rs:287`), and `sys_read` (`syscall/read.rs:39`) returns `-EFAULT` instead of `SyscallReturn::Return(read_len)`.

Result, visible copy, and open-file-description progress therefore disagree whenever `0 < copied_len < copy_len`: the syscall reports zero bytes, the user buffer holds a positive prefix of file data, and the shared offset never moves. This is exactly the counterexample's final state (`visibleTotal = 1`, `reportedTotal = 0`, `result = "Fault"`, `ofdOffset = 0`) violating `MCReportedCoversVisibleCopy`.

## Trigger scenario

Public syscalls only, unprivileged:

```c
m   = mmap(NULL, 3*PAGE, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
mprotect(m + PAGE, 2*PAGE, PROT_NONE);
buf = m + PAGE - 128;                 /* 128 writable bytes, then a hole */
fd  = open("/ext2/file", O_RDONLY);   /* file >= 1 page */
read(fd, buf, 8192);
```

`Vmo::read` copies page-cache page 0 with `copy_len = 4096`; `__memcpy_fallible` (`rep movsb` with an `.ex_table` fixup, `ostd/src/arch/x86/mm/memcpy_fallible.S`) copies 128 bytes and faults, so `copied_len = 128`. Not a contrived buffer — this is the shape of any buffer at the tail of an mmap arena next to a guard page, and the existing Specula trace harness already builds it (`specula_io_trace.c:112-117`).

## Developer intent

Issue #711 ("Wrong behavior when `EFAULT` occurs in the middle of I/O system calls", open since 2024-03-23) reports the same divergence with a same-shaped PoC, but attributes it to the then-current bounce-buffer implementation. That implementation is gone — PR #1156 replaced it with the `VmReader`/`VmWriter` design audited here — so the mechanism is new even though the symptom is the filed one. Nothing marks the erasure as deliberate: `error.rs:210` carries only `// Used in fallible memory read/write API`. `kernel/core/src/context.rs:96-107` documents the opposite intent, refusing an up-front pointer check specifically to preserve "delayed buffer validation"; discarding the resulting count defeats that. No test in `test/initramfs/src/regression/io/file_io/` pins the current behavior.

## Reproduction result

PASS — escalation Level 0 (pure black box). Test: `repro/test_bugMC-1_partial_read_efault.c` + driver `repro/test_bugMC-1_partial_read_efault.sh`.

Command:
```
cd .specula-output && ./repro/test_bugMC-1_partial_read_efault.sh
```
Build/boot reuses the known-good harness recipe: `asterinas/dev:0.18.1-20260805`, KVM, `make kernel SMP=2 CONSOLE=ttyS0 INITRAMFS_SKIP_GZIP=1`, then `make run_kernel ... SPECULA_INIT=/test/io/specula/run_mc1_repro.sh`. Only initramfs build wiring is modified; `git status --short -- kernel ostd` in the tree under test is empty (printed in the log below).

```
==============================================================
STEP 1  Linux control (same payload, host kernel 7.1.9)
==============================================================
MC-1 repro: positive read prefix exposed but reported as EFAULT
page=4096 writable_prefix=128 file_bytes=8192
---- /tmp/mc1-control/file-a (/tmp/mc1-control/file-a) ----
/tmp/mc1-control/file-a read      : ret=128 errno=0(-) offset_after=128 visible_prefix=128
/tmp/mc1-control/file-a next read : ret=128 first_byte='Y' (expected 'Y' if the delivered prefix is accounted for, 'A' if it is replayed)
/tmp/mc1-control/file-a pread     : ret=128 errno=0(-) visible_prefix=128
/tmp/mc1-control/file-a zero-prefix control: ret=-1 errno=14(Bad address) offset_after=0 (both kernels must report EFAULT here)
MC1_ANOMALIES 0
MC1_RESULT MATCHES_LINUX

==============================================================
STEP 2  Asterinas (pristine kernel + same payload as init)
==============================================================
--- kernel/ostd modifications in the tree under test (must be empty) ---
--- end ---
...
--- Asterinas guest output ---
MC-1 repro: positive read prefix exposed but reported as EFAULT
page=4096 writable_prefix=128 file_bytes=8192
---- ramfs (/mc1-regular-file) ----
ramfs read      : ret=-1 errno=14(Bad address) offset_after=0 visible_prefix=128
ramfs ANOMALY   : read() reported failure (Bad address) but 128 bytes of the user buffer were already overwritten with file data
ramfs next read : ret=128 first_byte='A' (expected 'Y' if the delivered prefix is accounted for, 'A' if it is replayed)
ramfs ANOMALY   : the 128 delivered bytes are replayed by the next read -- a caller that repairs its mapping and retries sees them twice
ramfs pread     : ret=-1 errno=14(Bad address) visible_prefix=128
ramfs ANOMALY   : pread() reported failure (Bad address) but 128 bytes of the user buffer were already overwritten with file data
ramfs zero-prefix control: ret=-1 errno=14(Bad address) offset_after=0 (both kernels must report EFAULT here)
---- ext2  (/ext2/mc1-regular-file) ----
ext2  read      : ret=-1 errno=14(Bad address) offset_after=0 visible_prefix=128
ext2  ANOMALY   : read() reported failure (Bad address) but 128 bytes of the user buffer were already overwritten with file data
ext2  next read : ret=128 first_byte='A' (expected 'Y' if the delivered prefix is accounted for, 'A' if it is replayed)
ext2  ANOMALY   : the 128 delivered bytes are replayed by the next read -- a caller that repairs its mapping and retries sees them twice
ext2  pread     : ret=-1 errno=14(Bad address) visible_prefix=128
ext2  ANOMALY   : pread() reported failure (Bad address) but 128 bytes of the user buffer were already overwritten with file data
ext2  zero-prefix control: ret=-1 errno=14(Bad address) offset_after=0 (both kernels must report EFAULT here)
MC1_ANOMALIES 6
MC1_RESULT DIVERGES_FROM_LINUX
MC1_SCENARIO_DONE

==============================================================
VERDICT
==============================================================
Linux host : MC1_RESULT MATCHES_LINUX
Asterinas  : MC1_RESULT DIVERGES_FROM_LINUX
MC-1 REPRODUCED
```

Lines that demonstrate the bug, against expected (correct) behavior:

| Observable | Linux (control) | Asterinas | CE prediction |
|---|---|---|---|
| `read()` result | `ret=128` | `ret=-1 EFAULT` | `result = "Fault"`, `reportedTotal = 0` |
| user buffer | `visible_prefix=128` | `visible_prefix=128` | `visibleTotal = 1` (positive) |
| shared offset | `offset_after=128` | `offset_after=0` | `ofdOffset = 0` |
| next `read()` | `first_byte='Y'` (stream continues) | `first_byte='A'` (replay) | — |

Negative control passes on both kernels: with the *whole* buffer unmapped, `copied_len = 0` and both return EFAULT with the offset at 0. So the divergence is specifically "EFAULT after a positive prefix", the mechanism the counterexample flags — not "EFAULT is wrong". The operations covered are `read` (shared offset) and `pread64` (positional) across both page-cache backends (ramfs and ext2 buffered).

### Pre-`REPRODUCED` checklist

1. **Did Level 0 or Level 1 alone trigger it?** **Yes** — Level 0. Only `mmap`, `mprotect`, `open`, `read`, `pread`, `lseek`. No failpoints, no timing assistance, no state injection, no kernel patch; the driver prints the empty `git status --short -- kernel ostd` for the tree under test.
2. **Level 2/3 pre-condition justification.** Not applicable; neither was used.
3. **Which real consumer observes a wrong outcome?** The userspace caller of `sys_read` — the error escapes at `kernel/core/src/syscall/read.rs:39`, so `SyscallReturn::Return(read_len)` at `:44` is never reached and the process gets `-1/EFAULT` where Linux gives `128`. Same for `sys_pread64`. Secondary: `fs::vfs::notify::on_access` at `read.rs:41-43` is skipped even though data was delivered.
4. **Permanent or masked?** Permanent, and no mechanism masks it. `read.rs:36-38` only rewrites `EINTR`→`ERESTARTSYS` and passes everything else through; `inode_handle.rs:287` returns before the offset update; nothing re-reads, re-syncs, or restores the clobbered buffer. The `next read` probe proves the state persists rather than self-correcting: because the offset never advanced, the 128 already-delivered bytes are handed out a second time.

## Recommendation

Stop erasing the count at the boundary. Two changes, in order of blast radius:

1. Make the count survive the copy layer. `Vmo::read`/`Vmo::write` return `Result<()>` and communicate progress only through the cursor, so the caller already *can* recover it — `ext2/inode/file.rs:241` and `ramfs/fs.rs:709` just need to measure the writer before/after and, on `Err`, return `Ok(copied)` when `copied > 0` instead of propagating. That alone fixes `read`/`pread64` on both backends and matches Linux's `filemap_read()` rule (`return already_read ? already_read : error`).
2. Delete or narrow `impl From<(ostd::Error, usize)> for Error` (`error.rs:209-214`). Its only purpose is to let `?` silently discard partial progress; as long as it exists, any new `?` on a fallible copy reintroduces this bug. Requiring an explicit `.map_err(|(e, n)| ...)` at each site makes the decision visible.

Also fix #711 in the same pass rather than as a separate report — the write path (`inode_handle.rs:319`, `ext2/inode/file.rs`, tracked here as MC-2) has the identical erasure, and a half-fix would leave `read` and `write` with different contracts.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running find /home/chin39/.claude ~/.config -iname "*bug-confirmation*" -maxdepth 6 2>/dev/null | head -20; echo "---"; find / -iname "*bug-confirmation*" -maxdepth...
running find /home/chin39/Documents/play/Specula/skills/bug-confirmation -type f | sort
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "===== SKILL.md =====" && cat SKILL.md && echo "===== guide.md =====" && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "===== phases/01-investigation.md =====" && cat phases/01-investigation.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "===== phases/02-reproduction.md =====" && cat phases/02-reproduction.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat references/repair-request-format.md
Now let me read Agent A's investigation record and repro artifacts.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now let me independently verify the code claims and the counterexample.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /tmp && timeout 120 gh issue view 711 --repo asterinas/asterinas --json number,title,state,createdAt,closedAt,url --jq '"\(.number) [\(.state)] \(.title)\...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Let me independently verify the load-bearing Linux-contract claim on this host, and check whether a full re-run is cheap.
running cd /tmp && cc -Wall -Werror -O2 -o /tmp/mc1_verify_b /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315...
running CACHE=${XDG_CACHE_HOME:-/tmp}/specula-asterinas-regular-file; echo "CACHE=$CACHE"; du -sh "$CACHE"/* 2>/dev/null; echo "=== worktree target ==="; du -sh /hom...
My independent Linux control matches. Now let me independently re-run the Asterinas half, preserving A's logs.
running set -eu BASE=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial...
running MYDIR=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
While that runs, let me verify the counterexample itself.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The counterexample's final state maps exactly onto the repro. Let me check the re-run progress.
running MYDIR=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
My independent re-run reproduces identically on a freshly built pristine kernel (driver exit 0). Let me record my challenge notes.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirm...
I attacked MC-1 on both bars and it survived. Notes: `.specula-output/confirmation/MC-1/challenge-turn02_B.md`.

## What I attacked, and what happened

**My best shot — the repro runs on an instrumented kernel.** A's driver builds with `ENABLE_SPECULA_TRACE=true`, which reads like kernel instrumentation. It isn't. I read every diff in the worktree: the root `Makefile` change adds only `ENABLE_SPECULA_TRACE ?= false` and `CARGO_OSDK_BUILD_ARGS += --init-args="$(SPECULA_INIT)"`; the nix diffs thread a *userspace* package into the initramfs closure. No kernel cargo feature, no `ostd`/`kernel` source change. `git status --short -- kernel ostd` is empty before and after. The guest payload is byte-identical to `repro/test_bugMC-1_partial_read_efault.c`.

**I did not take A's output at face value.** I re-ran the entire reproduction myself with `LOG_DIR` repointed so A's logs survive — full rebuild, fresh boot, driver exit 0, byte-for-byte the same result (`verify/rerun.out`). I also re-ran the Linux control myself against `/tmp`, which `stat -f` reports as ext2/ext3 — a closer control to the Asterinas ext2 case than A's tmpfs: `ret=128`, `offset_after=128`, next read continues at `'Y'`, `MC1_ANOMALIES 0`.

**All three MC artifact routes are affirmatively refuted, not merely unproven:**
- `SPEC_REPAIR` — the code takes the CE's decisive step, at Level 0, twice.
- `FAULT_MODEL` — nothing was injected; `mprotect(PROT_NONE)` is a public syscall, and the campaign's own Assumptions admit a copy that completes a positive prefix then faults.
- `INVARIANT` — Linux satisfies `ReportedCoversVisibleCopy` on the same binary, so the property is measured, not invented.

**No mask exists.** I looked. `read.rs:36-38` rewrites only `EINTR`→`ERESTARTSYS`; `inode_handle.rs:287` returns before `*offset += len`. The follow-up read proves permanence *and* escalates it: the offset never moved, so the 128 already-delivered bytes are handed out a second time.

**Verified independently:** every cited line via `git show HEAD:` (`io/mod.rs:354-358` advances `writer.cursor` before returning `Err`; `error.rs:209-214` drops the `usize`), and the CE's State 10 (`visibleTotal=1, reportedTotal=0, result=Fault, ofdOffset=0`) mapping 1:1 onto the guest output.

## Two corrections to the record, neither changing the verdict

- The CE's second thread `t2` is `Pending`/`visibleTotal=0` at the violating state. The violation is entirely `t1`'s single-threaded read, so A's single-threaded repro is a *simpler* instantiation than the CE — worth stating so the absent concurrency isn't later read as a partial match.
- Novelty was my other promising line: I confirmed #711 is still `OPEN`. It fails as a removal argument because the skill's known-drop pre-filter is code-review-only; A's `KNOWN (cite: …/issues/711; fix-status: unfixed)` is the correct handling and also satisfies the brief's "#711 is context, never a new finding."

I have no citable objection left, so I concede rather than manufacture one. No repair request — emitting one with all three routes refuted would be the fishing expedition the skill forbids.

---

## Entry 2: A retained write prefix is returned as EFAULT with no offset progress

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-2/debate.md

I'll start by reading the bug-confirmation skill in full, then investigate.
running find /home/chin39/.claude -type d -name "bug-confirmation" 2>/dev/null; echo "---"; find / -type d -name "bug-confirmation" -not -path "*/node_modules/*" 2>/...
running ls /home/chin39/.claude/skills/ 2>/dev/null | head -50; echo "=== plugins ==="; ls /home/chin39/.claude/plugins/ 2>/dev/null | head -30
running ls /home/chin39/.claude/skills/ | tail -30; echo "=== find bug-conf ==="; find /home/chin39/.claude/skills -maxdepth 2 -iname "*bug*" 2>/dev/null; echo "===...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && find . -type f | sort && echo "=== guide.md ===" && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat SKILL.md && echo "=============== PHASE 1 ===============" && cat phases/01-investigati...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/02-reproduction.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat references/repair-request-format.md
Now let me start Phase 1: Investigation.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running echo "=== docker ===" ; command -v docker && (timeout 30 docker info --format '{{.ServerVersion}}' 2>&1 | head -3) ; echo "=== kvm ===" ; ls -la /dev/kvm 2>&...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now let me investigate developer knowledge (Phase 1 Step 2).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running command -v gh && timeout 60 gh api rate_limit --jq '.rate' 2>&1 | head -5; echo "---network---"; timeout 20 curl -sS -o /dev/null -w "%{http_code}\n" https:/...
running cd /tmp && for q in "repo:asterinas/asterinas EFAULT partial write" "repo:asterinas/asterinas short write page fault" "repo:asterinas/asterinas partial copy...
running cd /tmp && for q in "EFAULT partial write" "short write page fault" "partial copy EFAULT write" "write_pages_with_backend"; do echo "=== $q ==="; timeout 60...
running cd /tmp && for q in "EFAULT" "partial write" "page cache dirty" "write_fallible" "short read"; do echo "=== ISSUES: $q ==="; timeout 60 gh search issues --re...
running cd /tmp && timeout 60 gh issue view 711 --repo asterinas/asterinas --json number,title,state,url,createdAt,updatedAt,body,comments 2>&1 | python3 -c " import...
running cd /tmp && echo "=== #3181 ===" && timeout 60 gh issue view 3181 --repo asterinas/asterinas --json number,title,state,url,createdAt,body 2>&1 | python3 -c "...
running cd /tmp && for q in "partial write page cache" "short write EFAULT" "page cache partial" "write_fallible partial"; do echo "=== PRs: $q ==="; timeout 60 gh s...
running cd /tmp && for q in "partial write page cache" "short write EFAULT" "page cache partial write" "EFAULT middle of I/O"; do echo "=== PRs: $q ==="; timeout 60...
running cd /tmp && timeout 60 gh pr view 3297 --repo asterinas/asterinas --json number,title,state,url,createdAt,body 2>&1 | python3 -c " import json,sys j=json.load...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now let me write the Phase 1 investigation record.
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now the reproduction payload (Level 0, public API only):
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running cd /tmp && REPRO=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-par...
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now the driver script:
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The bug reproduced at Level 0. Now let me pin the counterexample's exact page-state shape (faulting page `Uninit`).
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /tmp && echo "=== PRs referencing #711 ===" && timeout 60 gh search prs --repo asterinas/asterinas --json number,title,state,closedAt --limit 20 "711" 2>&...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
# MC-2 — A retained write prefix is returned as EFAULT with no offset progress

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/asterinas/asterinas/issues/711; fix-status: unfixed)
- **Location**: `kernel/core/src/vm/page_cache/vmo/mod.rs:745` (pristine; cited as `:734` in the instrumented tree) — `return Err(Error::from(err))` in `write_pages_with_backend`, with the count erased at `kernel/core/src/error.rs:209`
- **Severity**: High
- **Reproduction test**: `repro/test_bugMC-2_retained_write_prefix_efault.c` + `.sh`

## Pre-verdict checklist

1. **Level 0 or Level 1 alone?** **yes** — Level 0. The payload uses only `open/pwrite/pread/fsync/mmap/mprotect/lseek/write/close`. No failpoints, no timing help, no state injection, no source patch. The kernel under test is the pristine baseline: `git -C worktree status --short -- kernel ostd` printed nothing (line in the log between `--- kernel/ostd modifications … ---` and `--- end ---`). The only tree changes are initramfs build wiring that ships the test binary into the guest.
2. **Level 2/3 pre-condition:** not applicable — Level 0 triggered it.
3. **Real consumer observing the wrong outcome:** the userspace `write(2)` caller. In-kernel, `InodeHandle::write` (`kernel/core/src/fs/file/inode_handle.rs:317-319`) consumes the erased count and therefore never runs `*offset += len`; `sys_write` (`kernel/core/src/syscall/write.rs:33-38`) hands the caller `-EFAULT`. The changed bytes are then observed back through two ordinary read paths: buffered `pread` (`MC2_FILE … changed_bytes=4096`) and `O_DIRECT` `pread` via `Ext2Inode::read_direct_at` (`MC2_DIRECT … on_disk_changed_bytes=4096`).
4. **Permanent or masked?** **Permanent, no mask.** The prefix survives `fsync` and is read back from the ext2 block device through `O_DIRECT` in all three cases. `rollback_write` is a no-op for in-place ranges (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:205-208`) and cannot un-dirty a page anyway; the offset never catches up because the syscall returned an error.

## Description

`VmReader::read_fallible` reports a short user copy as `Err((Error::PageFault, copied_len))` (`ostd/src/mm/io/mod.rs:354`), carrying the bytes it did copy. `write_pages_with_backend` keeps those bytes — it dirties a page that was copied in full (Ok arm) or a faulting `UpToDate` page with a positive prefix (Err arm) — and then returns `Err(Error::from(err))`, where `impl From<(ostd::Error, usize)> for Error` (`kernel/core/src/error.rs:209`) throws the `usize` away. ext2's `write_at` rolls back only capacity above `old_size`, so the dirty prefix stays; `InodeHandle::write` propagates with `?` and leaves the shared offset untouched; `sys_write` returns `EFAULT`. The file changed, the syscall said nothing was written, and the offset did not move.

## Trigger scenario

Unprivileged, no concurrency, one syscall:

1. `mount -t ext2 /dev/vda /ext2` (the stock initramfs `init` already does this).
2. Create a regular file of `A`s, `fsync`, close, re-open `O_RDWR`.
3. `mmap` three anonymous pages of `B`s, `mprotect(base+4096, 8192, PROT_NONE)`, take `buf = base + 4096 - readable_bytes`.
4. `lseek` to the target offset, then a single `write(fd, buf, len)` covering more than the readable prefix.

Three page-state mixes were exercised; all three fail:

| case | shape | result |
|---|---|---|
| `mixed_page` | earlier page copied in full and dirtied (Ok arm), next page faults at 0 bytes | committed 4096, reported 0 |
| `partial_page` | fault inside one `UpToDate` page (Err arm, `written_size > 0 && state.is_up_to_date()`) | committed 128, reported 0 |
| `uninit_tail` | **counterexample's exact shape**: unaligned head page `UpToDate` (`CommitMode::Read`) takes the whole prefix, page-aligned middle committed `Uninit` (`CommitMode::Overwrite`) is the page that faults | committed 128, reported 0 |

`uninit_tail` matches State 6 of the trace — `MCFileOpsWriteAtCopyFaultPositive(t1,"Uninit","Positive")` — and reaches State 10's `result = Fault`, `copied = Positive`, `committed = Positive`, `reportedTotal = 0`, `committedTotal = 1`, `ofdOffset` unchanged, violating `MixedPageRetainedPrefixReported` (`spec/base.tla:559-567`) via the same code path the finding names.

## Developer intent

Issue **#711 — "Wrong behavior when `EFAULT` occurs in the middle of I/O system calls"** (OPEN, filed 2024-03-23) is this mechanism at this site; its PoC is a `write()` across a mapped/unmapped page boundary returning `EFAULT` where Linux returns a short count. Maintainer `lrh2000`, 2026-07-14:

> I think this issue still exists today. It seems that we do not allow partial reads or writes in our page cache implementation. However, I am not aware of any applications that depend on this behaviour. Therefore, perhaps the priority to fix this is very low.

— linking `kernel/src/vm/page_cache/vmo/mod.rs` L415/L547. The 2024 design discussion (`lrh2000`, `StevenJiang1110`) proposes returning `Result<usize>` so a partial copy reports `Ok(n)`: the intended behavior is a short count, not `EFAULT`. No PR has landed it (checked merged/closed page-cache PRs #3713, #3421, #3299, #3509, #2953, #3256, and #711's timeline: cross-referenced only by #699, #702, #1156, #1294, none fixing it). PR #3297 (`InodeRollbackGuard`, open draft) restructures ext2 rollback without touching progress reporting.

The in-code comment `// If the page is not initialized, keep it as it is on a partial write.` shows the author reasoned about partial-write *data* retention; nothing anywhere reasons about *reporting* it. What #711 does not state — and the counterexample adds — is that the failing `write()` leaves committed file data behind. That is an aggravation of the same defect at the same site, so novelty stays KNOWN.

## Reproduction result

PASS. `timeout 3000 ./repro/test_bugMC-2_retained_write_prefix_efault.sh` (full log: `confirmation/MC-2/repro-run.log`).

```
STEP 1  Linux control (same payload, host kernel 7.1.9)
MC2_CASE mixed_page setup=buffered file_bytes=8192 warm_bytes=8192 write_off=0 write_len=8192 readable_bytes=4096
MC2_WRITE mixed_page ret=4096 errno=0(none)
MC2_OFFSET mixed_page before=0 after=4096 delta=4096
MC2_FILE mixed_page changed_bytes=4096 first_changed=0 last_changed=4095
MC2_DIRECT mixed_page on_disk_changed_bytes=4096
MC2_VERDICT mixed_page CONSISTENT_SHORT_WRITE reported=4096 committed=4096 offset_delta=4096
MC2_CASE partial_page setup=buffered file_bytes=8192 warm_bytes=8192 write_off=0 write_len=8192 readable_bytes=128
MC2_WRITE partial_page ret=128 errno=0(none)
MC2_OFFSET partial_page before=0 after=128 delta=128
MC2_FILE partial_page changed_bytes=128 first_changed=0 last_changed=127
MC2_VERDICT partial_page CONSISTENT_SHORT_WRITE reported=128 committed=128 offset_delta=128
MC2_CASE uninit_tail setup=o_direct file_bytes=12288 warm_bytes=4096 write_off=3968 write_len=8320 readable_bytes=128
MC2_WRITE uninit_tail ret=128 errno=0(none)
MC2_OFFSET uninit_tail before=3968 after=4096 delta=128
MC2_FILE uninit_tail changed_bytes=128 first_changed=3968 last_changed=4095
MC2_VERDICT uninit_tail CONSISTENT_SHORT_WRITE reported=128 committed=128 offset_delta=128
MC2_RESULT MATCHES_LINUX

STEP 2  Asterinas (pristine kernel + same payload as init)
--- kernel/ostd modifications in the tree under test (must be empty) ---
--- end ---
--- Asterinas guest output ---
MC2_DIR /ext2
MC2_CASE mixed_page setup=buffered file_bytes=8192 warm_bytes=8192 write_off=0 write_len=8192 readable_bytes=4096
MC2_WRITE mixed_page ret=-1 errno=14(Bad address)
MC2_OFFSET mixed_page before=0 after=0 delta=0
MC2_FILE mixed_page changed_bytes=4096 first_changed=0 last_changed=4095
MC2_DIRECT mixed_page on_disk_changed_bytes=4096
MC2_VERDICT mixed_page RETAINED_PREFIX_UNREPORTED reported=0 committed=4096 offset_delta=0
MC2_CASE partial_page setup=buffered file_bytes=8192 warm_bytes=8192 write_off=0 write_len=8192 readable_bytes=128
MC2_WRITE partial_page ret=-1 errno=14(Bad address)
MC2_OFFSET partial_page before=0 after=0 delta=0
MC2_FILE partial_page changed_bytes=128 first_changed=0 last_changed=127
MC2_DIRECT partial_page on_disk_changed_bytes=128
MC2_VERDICT partial_page RETAINED_PREFIX_UNREPORTED reported=0 committed=128 offset_delta=0
MC2_CASE uninit_tail setup=o_direct file_bytes=12288 warm_bytes=4096 write_off=3968 write_len=8320 readable_bytes=128
MC2_WRITE uninit_tail ret=-1 errno=14(Bad address)
MC2_OFFSET uninit_tail before=3968 after=3968 delta=0
MC2_FILE uninit_tail changed_bytes=128 first_changed=3968 last_changed=4095
MC2_DIRECT uninit_tail on_disk_changed_bytes=128
MC2_VERDICT uninit_tail RETAINED_PREFIX_UNREPORTED reported=0 committed=128 offset_delta=0
MC2_RESULT DIVERGES_FROM_LINUX

VERDICT
Linux host : MC2_RESULT MATCHES_LINUX
Asterinas  : MC2_RESULT DIVERGES_FROM_LINUX
MC-2 REPRODUCED
```

The lines that demonstrate the bug are the three `MC2_VERDICT … RETAINED_PREFIX_UNREPORTED reported=0 committed=N offset_delta=0` in the guest output, each paired with `MC2_DIRECT … on_disk_changed_bytes=N` proving the retained bytes reached the block device. Expected (Linux, same binary, same buffer): `ret=N`, `delta=N`, `changed_bytes=N` — reported, committed, and offset all agree.

Corroborating, from a pre-existing instrumented run (`traces/ext2_buffered.ndjson`, records 13-17): `FileOpsWriteAtCopyFaultPositive {"retained_prefix":"Positive"} page_state=Uninit` → `VmoWritePagesWithBackendFaultRetain` → `SysPwrite64Return result=Fault committed_total=1 reported_total=0`.

## Recommendation

Stop erasing the count on the buffered path. Concretely:

1. Make the page-cache write API return committed bytes instead of a bare error: have `Vmo::write` / `write_pages_with_backend` return `Result<usize, (Error, usize)>` (or thread `reader.remain()` back out — the reader cursor is already advanced by exactly the copied amount at `ostd/src/mm/io/mod.rs:355-356`, so no new bookkeeping is needed).
2. In `InodeInner::write_at` (`kernel/core/src/fs/fs_impls/ext2/inode/file.rs:245-271`), on a partial failure with `n > 0`, commit what was written — `set_mtime_ctime`, and `set_file_size(offset + n)` when it grew — and return `Ok(n)`. Keep the current all-or-nothing rollback only when `n == 0`.
3. In `InodeHandle::write` (`kernel/core/src/fs/file/inode_handle.rs:317-319`), advance `*offset` by the returned count and report it; surface `EFAULT` only when nothing was copied. Same shape for the read side.
4. `impl From<(ostd::Error, usize)> for Error` (`kernel/core/src/error.rs:209`) is the trap that makes this silent — every `?` on a fallible copy discards progress. Consider removing it so each call site must decide explicitly, as #711's own discussion proposed (`Result<usize>` / `MustUse<usize>`).

Until then, a failing buffered `write()` on ext2 can leave a durable, unreported, unattributed modification in the file: an application that retries from its own offset after `EFAULT` will duplicate the committed prefix, and one that treats `EFAULT` as "nothing happened" leaves the file silently corrupted.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running find / -name "*.md" -path "*bug-confirmation*" 2>/dev/null | head -20
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running ls -d /home/chin39/.claude/skills/*bug-confirmation* /home/chin39/.claude/plugins/*/skills/*bug-confirmation* 2>/dev/null; ls /home/chin39/.claude/skills/ 2>...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && find . -type f | sort && echo "=== SKILL.md ===" && cat SKILL.md
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat guide.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/02-reproduction.md
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /tmp && timeout 90 gh issue view 711 --repo asterinas/asterinas --json number,title,state,createdAt,body,comments 2>&1 | python3 -c " import json,sys raw=...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
I attacked both bars and could not break either. Notes: `.specula-output/confirmation/MC-2/turn02_B.notes.md`.

## Reachability — attacked, survived

**The instrumentation attack (my best shot).** The driver builds with `ENABLE_SPECULA_TRACE=true`, which reads like kernel instrumentation. It isn't: `git diff -- Makefile` shows the flag only gates the initramfs harness build and adds `--init-args=$(SPECULA_INIT)`; `git status --short -- kernel ostd` is empty; `grep -rn specula kernel ostd` returns four unrelated "speculative" comments in `ostd/src/mm/page_prop.rs`. No kernel/ostd code exists that the flag could turn on. Pristine at `2cd6429`.

**CE correspondence — I re-derived it rather than trusting the log.** From `Vmo::write` (pristine `vmo/mod.rs:606-639`), the `uninit_tail` write 3968..12288 splits into head 3968..4096 (`CommitMode::Read` → UpToDate, warmed) and mid 4096..12288 (`CommitMode::Overwrite` → Uninit, cold via O_DIRECT setup). Readable prefix 128 = exactly the head length, so head copies in full (`Ok` arm → `set_dirty`) and the first Uninit page faults at 0 bytes. Predicted committed range: 3968..4095. Guest observed `changed_bytes=128 first_changed=3968 last_changed=4095`. That matches CE State 10 (`pageState=Uninit, copied=Positive, committed=Positive, result=Fault, reportedTotal=0, committedTotal=1`) violating `MixedPageRetainedPrefixReported` at `spec/base.tla:558-567`.

## Consequence — hunted for the mask, there is none

- `rollback_write` (`ext2/inode/file.rs:204-208`) early-returns for `end <= old_size`; all three cases are in-place, so rollback is a literal no-op, and it structurally cannot un-dirty a page.
- No fault-in/retry loop anywhere on the write path. `write_pages_with_backend` returns `Err(Error::from(err))` (`vmo/mod.rs:745`), `From<(ostd::Error, usize)>` (`error.rs:209`) drops the count, `InodeHandle::write` uses `?` so `*offset += len` never runs.
- Durability holds: `read_direct_at` flushes overlapping pages before reading the device, plus an explicit `fsync` — `on_disk_changed_bytes=N` in all three guest cases.
- The retry angle doesn't save it: a caller that treats EFAULT as "nothing written" is left with a durably half-modified file and no way to learn how much landed. Worst case `mixed_page`: **4096 bytes committed and on disk, `write()` returns -1/EFAULT, offset delta 0**, against `ret=4096` on Linux from the identical binary.

## Routing attacks all fail

`FAULT_MODEL` — the campaign's own Assumptions admit a positive-prefix-then-fault copy, and the fault came from real `mprotect`. `INVARIANT` — the flagged state isn't benign, and #711's design thread proposes `Ok(n)`, i.e. short count is the promised behavior. `MASKED`/`ENV_LIMITED` — the harm manifested live. `FALSE POSITIVE`/`DROPPED` — unavailable for MC, and `guide.md`'s only pre-filter is code-review-only.

## Known-status, verified myself

I opened issue #711 directly: **OPEN**, maintainer 2026-07-14 "this issue still exists today … priority to fix this is very low." Low priority is not intent. `KNOWN (cite: issues/711; fix-status: unfixed)` must stay on the record — the campaign bars presenting #711 as new, and A's label complies. The delta I confirmed in the issue body: #711's PoC asserts only `write()`'s return value and never inspects the file, so the durable-committed-data half is genuinely new.

## One correction for A (not verdict-changing)

`affected_code` uses instrumented-tree line numbers. Pristine: `vmo/mod.rs:745` (not 734), `ext2/inode/file.rs:262-265` (not 353), `inode_handle.rs:317-318` (not 367). `ostd/src/mm/io/mod.rs:354` and `error.rs:209` are correct.

I concede — the finding clears both bars on a pristine kernel at escalation Level 0, with a Linux control on the same binary.

---

## Entry 3: Ramfs can copy beyond logical EOF and report only the EOF snapshot

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-3/debate.md

I'll start by reading the bug-confirmation skill in full.
running find /home/chin39/.claude -type d -name "bug-confirmation" 2>/dev/null; echo "---"; find / -type d -name "bug-confirmation" -not -path "*/node_modules/*" 2>/...
running ls /home/chin39/.claude/skills/ 2>/dev/null | head -50; echo "=== plugins ==="; ls /home/chin39/.claude/plugins/ 2>/dev/null | head
running ls /home/chin39/.claude/skills/ | tail -30; echo "=== search bug-conf ==="; ls -d /home/chin39/.claude/skills/*bug* /home/chin39/.claude/skills/*specula* 2>/...
running cd /home/chin39/Documents/play/Specula 2>/dev/null && ls; echo "=== skills in Specula ==="; find /home/chin39/Documents/play/Specula -maxdepth 4 -type d -nam...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && find . -type f | sort && echo "=== guide.md ===" && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "=== SKILL.md ===" && cat SKILL.md && echo "" && echo "=== phases/01-investigation.md...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/02-reproduction.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat references/repair-request-format.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running which gh curl 2>&1; echo "---"; timeout 25 curl -sS -o /dev/null -w "%{http_code}\n" https://api.github.com/rate_limit 2>&1 | tail -2
running set -o pipefail q() { timeout 40 curl -sS -H "Accept: application/vnd.github+json" "https://api.github.com/search/issues?q=$1" | python3 -c " import sys,json...
running timeout 40 curl -sS "https://raw.githubusercontent.com/asterinas/asterinas/main/kernel/core/src/fs/fs_impls/ramfs/fs.rs" -o /tmp/upstream_ramfs.rs && grep -n...
running timeout 40 curl -sS -H "Accept: application/vnd.github+json" "https://api.github.com/repos/asterinas/asterinas/commits?path=kernel/core/src/fs/fs_impls/ramfs...
running timeout 60 gh api "repos/asterinas/asterinas/commits?path=kernel/core/src/fs/fs_impls/ramfs/fs.rs&per_page=10" --jq '.[] | "\(.sha[0:9]) \(.commit.author.dat...
running echo "### search: ramfs EOF read"; timeout 60 gh search issues --repo asterinas/asterinas "ramfs read beyond file size" --limit 10 2>&1 | head -12 echo "###...
running echo "### A"; timeout 60 gh search issues --repo asterinas/asterinas "ramfs" --limit 20 --json number,title,state,url --jq '.[] | "\(.number) \(.state) \(.ti...
running echo "docker: $(docker --version 2>&1 | head -1)"; ls -l /dev/kvm 2>&1; echo "=== images ==="; timeout 60 docker images 2>&1 | grep -i asterinas | head; echo...
running du -sh /home/chin39/.cache/specula-asterinas-regular-file/* 2>/dev/null; echo "=== MC-2 worktree target dir (prebuilt?) ==="; du -sh /home/chin39/Documents/p...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now let me set up the reproduction. First, revert the kernel to pristine (Level 0 requires an unmodified system under test):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /tmp && cc -Wall -Werror -O2 -o /tmp/mc3_repro_host "/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030...
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now let me launch the full reproduction (it will block until the Asterinas build+boot finishes):
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The build is running. While it works, let me write the Phase 1 investigation record:
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirm...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Reproduced at Level 0. Let me verify the guest ran the pristine kernel and check for in-kernel consumers:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Reproduced at escalation Level 0 on a pristine kernel. Here is the verdict.

- **Source**: MC
- **Novelty**: NEW
- **Location**: kernel/core/src/fs/fs_impls/ramfs/fs.rs:709

## Description

`RamInode::read_at` computes its return value by clamping the request to logical EOF, but hands the page cache the caller's **unclamped** `VmWriter`:

```rust
let (offset, read_len) = { ... (start, end - start) };   // clamped to file_size
page_cache.lock().read(offset, writer)?;                 // full writer.avail()
read_len                                                 // the reported length
```

`Vmo::read` (`vm/page_cache/vmo/mod.rs:534-537`) bounds the copy by `Vmo::size()` — the *page-aligned cache capacity*, which the page-cache API explicitly documents as possibly exceeding the file size, leaving EOF tracking to the filesystem (`vm/page_cache/mod.rs:181-186`). A 2-byte ramfs file has a 4096-byte cache, so `pread(fd, buf, 64, 1)` returns 1 while writing 64 bytes of the caller's buffer. Bytes in `[return_value, requested_len)` — which POSIX guarantees untouched — get zeroed, up to `PAGE_SIZE - 1` bytes per call. The over-copy never leaves the user's buffer, and the extra bytes are zeros (anon cache pages come from `CachePage::alloc_zero()`, truncation zero-fills the tail page), so this is a buffer-integrity/contract defect, not a memory-safety issue or a kernel-memory leak. `RamFs` backs the boot rootfs, `tmpfs`, `/dev/shm` and `devtmpfs`, so every file on those filesystems is affected. Positional-offset neutrality is intact, exactly as the counterexample showed (`MCPositionalOffsetStable` did not fail).

## Trigger scenario

Single-threaded, no faults, no concurrency — the counterexample's own trace (`MCSysPread64Start(t1,"Ramfs",1)`, `fileSize = 2`):

1. `fd = open("/mc3/f", O_CREAT|O_RDWR)` on ramfs; `pwrite(fd, "AB", 2, 0)`. File size 2, page-cache capacity 4096.
2. `memset(buf, 0x5a, 64); pread(fd, buf, 64, 1);`
3. Linux: returns 1, `buf[1..64)` still `0x5a`. Asterinas: returns 1, `buf[1..64)` zeroed.

Same defect through `read(2)` on the shared offset, through `preadv(2)` (a later iovec entry starting at EOF is clobbered although the return value excludes it), and at scale — on a 4100-byte file one `pread` returning 4 scribbles 4092 bytes.

## Developer intent

No comment, TODO or FIXME at the site claims this is intended. The rest of the tree does the opposite:

- **ext2 clamps** with the same page-cache API: `let read_len = writer.avail().min(file_size - offset); writer.limit(read_len); self.page_cache().read(offset, writer)?;` (`fs_impls/ext2/inode/file.rs:239-242`). virtiofs does the same (`virtiofs/inode/ops.rs:75`).
- **ramfs itself uses `limit()`** on the write side for `F_SEAL_GROW` (`ramfs/memfd.rs:139`), citing Linux `mm/shmem.c`.
- The page-cache contract assigns EOF tracking to the filesystem (`vm/page_cache/mod.rs:181-186`).
- No existing test asserts the current behavior.

Prior-report search (issues **and** merged/closed PRs, via GitHub API and `gh`): `ramfs read EOF`, `"beyond EOF"`, `"writer.limit"`, `ramfs read_at`, `RamInode`, `tmpfs short read`, `page cache EOF` — nothing reports this mechanism. The five most recent upstream commits touching `ramfs/fs.rs` (newest `1d5dad707`, 2026-08-20) are rename/visibility/xattr changes. `main`'s current `ramfs/fs.rs:695-719` is byte-identical to the baseline: unfixed upstream today.

## Reproduction result

PASS — escalation **Level 0** (public syscalls only: `open`/`ftruncate`/`pwrite`/`pread`/`read`/`lseek`/`preadv`; no failpoints, no timing help, no source patch). Kernel under test is the pristine baseline: `git status --short -- kernel ostd` in the worktree is empty (printed by the driver, empty in the output below). Only initramfs build wiring ships the payload into the guest.

Command:

```
.specula-output/repro/test_bugMC-3_ramfs_read_past_eof.sh
```

Output:

```
==============================================================
STEP 1  Linux control (same payload, tmpfs, host kernel 7.1.9)
==============================================================
MC-3 repro: filesystem under test = /dev/shm/mc3-control
[case1 pread(off=1,len=64,size=2)] ret=1 (expected 1) untouched_range=[1,64) clobbered=0 first_clobbered=-1 -> OK
[case2 pread(off=EOF=2,len=64)] ret=0 (expected 0) untouched_range=[0,64) clobbered=0 first_clobbered=-1 -> OK
[case3 read(off=1,len=64,size=2)] ret=1 (expected 1) untouched_range=[1,64) clobbered=0 first_clobbered=-1 -> OK
[case3 offset] after read the shared offset is 2 (expected 2) -> OK
[case4 preadv(off=1, iov=[2,64], size=2)] ret=1 (expected 1)
[case4 entry0 tail] ret=1 (expected 1) untouched_range=[1,2) clobbered=0 first_clobbered=-1 -> OK
[case4 entry1 (starts at EOF)] ret=1 (expected 1) untouched_range=[0,64) clobbered=0 first_clobbered=-1 -> OK
[case5 pread(off=4096,len=4096,size=4100)] ret=4 (expected 4) untouched_range=[4,4096) clobbered=0 first_clobbered=-1 -> OK
MC3_SUMMARY wrong_return_values=0 buffers_modified_past_return=0
MC3_RESULT MATCHES_LINUX
MC3_SCENARIO_DONE

==============================================================
STEP 2  Asterinas (pristine kernel + same payload as init)
==============================================================
--- kernel/ostd modifications in the tree under test (must be empty) ---
--- end ---

--- Asterinas guest output ---
MC-3 repro: filesystem under test = /mc3
[case1 pread(off=1,len=64,size=2)] ret=1 (expected 1) untouched_range=[1,64) clobbered=63 first_clobbered=1 -> VIOLATION
[case2 pread(off=EOF=2,len=64)] ret=0 (expected 0) untouched_range=[0,64) clobbered=64 first_clobbered=0 -> VIOLATION
[case3 read(off=1,len=64,size=2)] ret=1 (expected 1) untouched_range=[1,64) clobbered=63 first_clobbered=1 -> VIOLATION
[case3 offset] after read the shared offset is 2 (expected 2) -> OK
[case4 preadv(off=1, iov=[2,64], size=2)] ret=1 (expected 1)
[case4 entry0 tail] ret=1 (expected 1) untouched_range=[1,2) clobbered=1 first_clobbered=1 -> VIOLATION
[case4 entry1 (starts at EOF)] ret=1 (expected 1) untouched_range=[0,64) clobbered=64 first_clobbered=0 -> VIOLATION
[case5 pread(off=4096,len=4096,size=4100)] ret=4 (expected 4) untouched_range=[4,4096) clobbered=4092 first_clobbered=4 -> VIOLATION
MC3_SUMMARY wrong_return_values=0 buffers_modified_past_return=6
MC3_RESULT DIVERGES_FROM_LINUX
MC3_SCENARIO_DONE

==============================================================
VERDICT
==============================================================
Linux host : MC3_RESULT MATCHES_LINUX
Asterinas  : MC3_RESULT DIVERGES_FROM_LINUX
MC-3 REPRODUCED
```

The demonstrating lines are `clobbered=63` (case1), `clobbered=64` on a `ret=0` EOF read (case2), and `clobbered=4092` (case5): bytes the syscall modified but did not report. Same lines read `clobbered=0` on Linux.

Right bug, not a different one: case1 is the counterexample's action verbatim (pread64, Ramfs backend, explicit offset 1, file size 2, request spanning EOF); the violated property is `MCReportedCoversVisibleCopy` (`reportedTotal = 1 < visibleTotal = 2` in the trace; `ret=1` vs 64 modified bytes in the run); the root cause is the cited line `ramfs/fs.rs:709`. `MCPositionalOffsetStable` held in the model, and case3 confirms the shared offset advances by exactly the reported length.

### Pre-`REPRODUCED` checklist

1. **Did Level 0 or Level 1 alone trigger it?** **Yes** — Level 0. Public syscalls on an unmodified kernel; no failpoints, no sleeps, no state injection, no source patch. Deterministic across all five cases.
2. **Level 2/3 pre-condition:** not used, so nothing to justify.
3. **Real consumer observing the wrong outcome:** userspace, through `sys_pread64` (`kernel/core/src/syscall/pread64.rs:33-40`), `sys_read` (`kernel/core/src/syscall/read.rs:28-43`) and `sys_preadv` (`kernel/core/src/syscall/preadv.rs:101-115`) — each returns the EOF-clamped length after the writer has already modified more of the caller's buffer. Demonstrated live in the guest run, not argued. (The in-kernel callers I checked — `program_loader/mod.rs:50`, `elf/load_elf.rs:128`, `elf/elf_file.rs:403` — slice by the returned length, so those particular paths are unharmed; that masks the in-kernel path only, not the syscall path reproduced here.)
4. **Permanent or masked?** Permanent. The corrupted bytes are delivered into the caller's buffer and the syscall returns; no sync, resend, loopback or guard repairs them. Each case asserts buffer state *after* the call returns.

## Recommendation

Limit the writer to the EOF-clamped length before handing it to the page cache, exactly as ext2 does:

```rust
let (offset, read_len) = { ... };
writer.limit(read_len);
page_cache.lock().read(offset, writer)?;
```

Two follow-ups worth folding into the same change:

- The size snapshot (`self.size()`) is taken *before* `page_cache.lock()`, so a concurrent truncate can shrink the file between the snapshot and the copy. Take the snapshot inside the page-cache critical section so the clamp and the copy agree.
- The same shape is worth a regression test on ramfs/tmpfs — read past EOF, read exactly at EOF, and `readv` straddling EOF, asserting the buffer beyond the return value is untouched. `repro/test_bugMC-3_ramfs_read_past_eof.c` can be adapted directly as a `test/initramfs/src/regression` case.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation 2>/dev/null && find . -type f | sort && echo "===== SKILL.md =====" && cat SKILL.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "===== 01-investigation ====="; cat phases/01-investigation.md; echo; echo "===== 02-r...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The finding's code claims and run log check out. Now let me verify the mechanism's edge (zeros vs. stale data) and probe whether a realistic consumer is actually harmed — that's the bar I can most usefully attack.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now I'll write my own challenger payload — testing whether a *realistic consumer* is actually harmed, plus a negative control and a stale-data check.
running cat > "/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running mkdir -p /dev/shm/mc3c-control && /tmp/mc3c_host /dev/shm/mc3c-control 2>&1 | tee /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-par...
running cat > "/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
My run reproduces A's result independently and adds consumer-level harm. Let me verify two remaining details before I settle: that no clamp exists anywhere on the syscall path, and whether A's recommended fix (`writer.limit`) is actually sound for the shared `&mut VmWriter`.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Both bars held under attack. Let me record my challenge notes.
running cat > "/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
I attacked both bars with my own reproduction rather than desk-reviewing A's. Neither bar broke.

## Bar 1 — Reachability: nothing to attack

Level 0 in my own independent run: unprivileged public syscalls only, single thread, no faults, no failpoints, no source patch. `git status --short -- kernel ostd` in the tree under test is empty before **and** after my run — only initramfs wiring is added. `/mc3` sits on the RamFs rootfs (`mount_namespace.rs:102` → `ramfs/fs.rs:64`). The CE step `MCSysPread64Start(t1,"Ramfs",1)`, `fileSize = 2`, is instantiated verbatim, not approximated.

## Bar 2 — Consequence: I hunted the mask and it doesn't cover the reproduced path

Read, not assumed: `sys_pread64` hands `user_space.writer(ptr, len)` straight through (`syscall/pread64.rs:33-37`); `InodeHandle::read`/`read_at` forwards unchanged (`inode_handle.rs:273-291`, `396-406`); `Vmo::read` bounds by page-aligned capacity by documented design (`vmo/mod.rs:534-535`, contract at `page_cache/mod.rs:181-186`). The one real mask — in-kernel ELF-loader callers slicing by the returned length — covers only in-kernel paths, not the syscall path. Harm is permanent: every assertion is made after the syscall returns.

## What my run added (`repro/test_bugMC-3_eof_consumer_harm.{c,sh}`)

One boot, both payloads. A's six violations reproduced byte-for-byte, plus:

| Case | Linux | Asterinas |
|---|---|---|
| C1 old-format record read over caller defaults | `timeout_ms=5000 retries=3 name="default-profile"` | `timeout_ms=0 retries=0 name=""` — **WRONG_OUTCOME** |
| C2 `preadv` iov[1] = live unrelated object | magic + payload intact 60/60 | magic zeroed, payload 0/60 — **WRONG_OUTCOME** |
| C3 past-EOF window after truncate | untouched | `zeroed=4086 stale_pre_truncate=0` |
| C4 **negative control**: page-aligned file (cap == EOF) | no clobber | **no clobber — control HELD** |

C4 was my strongest available objection — "the test just measures Asterinas zeroing buffers." It held: with capacity == EOF nothing past EOF is touched, which pins the defect to exactly the cited mechanism (page-aligned capacity exceeding logical EOF at `ramfs/fs.rs:709`). C1/C2 lift the harm from "sentinel bytes differ" to an application-level wrong result. C3 settles severity in A's favor: zeros, not resurrected pre-truncate content — a contract/integrity defect, not a disclosure. Medium is right.

## Two corrections to the fix shape (not the verdict)

- `VmWriter::limit(&mut self, ..) -> &mut Self` (`ostd/src/mm/io/mod.rs:919-925`) permanently shrinks the caller's writer. The ext2 form is safe only because each iovec entry gets a fresh writer; virtiofs's `clone_exclusive()` + `limit()` + `writer.skip(read_len)` (`virtiofs/inode/ops.rs:74-79`) is the safer form for a shared `&mut VmWriter`.
- The fix must cover `read_len == 0` — that is the case2/C2 shape (returns 0, still clobbers 64 bytes). ext2 early-returns (`ext2/inode/file.rs:233-236`); ramfs has no such guard.

Notes: `.specula-output/confirmation/MC-3/challenge-notes-turn02_B.md`; run log `challenge-run.log`.

---

## Entry 4: Ramfs publishes file size before a write that copies no bytes

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-4/debate.md

I'll start by reading the bug-confirmation skill and the finding's artifacts.
running ls /home/chin39/.claude/skills/ 2>/dev/null; echo "---"; find /home/chin39/.claude -iname "*bug-confirmation*" -maxdepth 4 2>/dev/null | head -20; echo "---...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running find / -iname "*bug-confirmation*" -maxdepth 8 2>/dev/null | head -30; echo "=== specula skills ==="; find /home/chin39/Documents/play/Specula -maxdepth 3 -t...
running ls /home/chin39/Documents/play/Specula/ 2>/dev/null; echo "=== "; find /home/chin39/Documents/play/Specula -maxdepth 4 -iname "guide.md" -not -path "*/runs/*...
running kill %1 2>/dev/null; cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && ls -R | head -40; echo "=== GUIDE ==="; cat guide.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running command -v docker; docker images 2>/dev/null | head -20; ls -l /dev/kvm 2>&1; nproc; free -g | head -3
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running stat -f -c %T /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partia...
Now I have the full picture. Let me set up the reproduction environment.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
using ToolSearch
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running command -v gh && timeout 60 gh api /repos/asterinas/asterinas --jq '.full_name,.pushed_at' 2>&1 | head -5
running cat /tmp/claude-1000/-home-chin39-Documents-play-Specula-runs-asterinas-syscall-regular-file-partial-progress-20260823T030315Z-asterinas-syscall-regular-file...
Environment is ready. Writing the reproduction test:
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The Linux control corrected one of my assumptions (case D): tmpfs moves `i_size` to the write *start* offset (`pos + copied`, copied = 0), never to `pos + len`. Fixing the reference expectation:
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Linux control is clean (0 deviations). Now launching the full run including the Asterinas guest build:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /tmp && timeout 120 gh search issues --repo asterinas/asterinas --state all --limit 30 "ramfs write size" 2>&1 | head -40; echo "=== 2 ==="; timeout 120 g...
running cd /tmp && timeout 120 gh search prs --repo asterinas/asterinas --state all --limit 30 "ramfs write_at" 2>&1 | head -40; echo "=== partial write ==="; timeou...
running cd /tmp && for q in "ramfs write size" "ramfs size EFAULT" "write_at file size" "partial write file size"; do echo "### QUERY: $q"; timeout 120 gh search iss...
running cd /tmp && echo "### ramfs"; timeout 120 gh search issues --repo asterinas/asterinas --include-prs --limit 20 ramfs 2>&1 | head -25; echo; echo "### EFAULT";...
running cd /tmp && timeout 120 gh issue view 711 --repo asterinas/asterinas --json number,title,state,createdAt,updatedAt,labels,body,comments --jq '{n:.number,t:.ti...
running cd /tmp && for q in "inode size write fail" "file size not restored" "size before copy" "zero-length write" "write extends file"; do echo "### $q"; timeout 9...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The guest run finished. Let me verify the full driver output and that the kernel was pristine:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /tmp && echo "### recent merged PRs touching ramfs"; timeout 120 gh api "/search/issues?q=repo:asterinas/asterinas+type:pr+is:merged+ramfs+in:title&per_pa...
running cd /tmp && timeout 120 gh api "/repos/asterinas/asterinas/contents/kernel/core/src/fs/fs_impls/ramfs/fs.rs?ref=main" --jq '.content' 2>/dev/null | base64 -d...
running cd /tmp && echo "### PRs mentioning write_at (any state)"; timeout 120 gh api "/search/issues?q=repo:asterinas/asterinas+write_at&per_page=20" --jq '.items[]...
running cd /tmp && timeout 120 gh pr view 3297 --repo asterinas/asterinas --json number,title,state,createdAt,updatedAt,body,files --jq '{n:.number,t:.title,s:.state...
running cd /tmp && timeout 120 gh pr view 3086 --repo asterinas/asterinas --json number,title,state,mergedAt,body,files --jq '{n:.number,t:.title,s:.state,merged:.me...
One gap: the counterexample's write starts *inside* the file (offset 1 < size 2 < end 3). Let me add that exact geometry as case E and re-run:
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /tmp && for q in "rollback ramfs" "tmpfs file size" "st_size incorrect" "metadata rollback write" "inode size rollback"; do echo "### $q"; timeout 90 gh s...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
The reproduction is complete and reproducible. Writing the investigation record:
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirm...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Investigation and reproduction are complete.

- **Source**: MC (real counterexample: `spec/output/MC_hunt_scenario_2_backend_publication_bfs.out`, `MCFileSizeMatchesProgress` violated, `fileSize=3` vs `expectedFileSize=2`)
- **Novelty**: NEW
- **Location**: `kernel/core/src/fs/fs_impls/ramfs/fs.rs:742` (publication) — fallible copy at `:750`; pristine-tree line numbers, upstream `main` byte-identical today

## Description

`RamInode::write_at` computes `new_size = offset + reader.remain()` — the *requested* end — and writes it into the inode metadata at `fs.rs:742` before performing the user copy at `fs.rs:750`. The copy is fallible, and nothing restores the size when it fails. A `pwrite`/`write` whose user buffer faults on its very first byte therefore returns `EFAULT` having copied, committed and reported zero bytes, yet leaves the file permanently longer. The same publication ordering makes a zero-length write past EOF grow the file while returning success. The never-written range becomes readable zeros rather than EOF, so `st_size` (`syscall/stat.rs:200`), `lseek(SEEK_END)` and `read` all report data the file never received.

The finding's timestamp sub-claim does not hold up: Linux also stamps mtime/ctime before the copy (`__generic_file_write_iter` → `file_update_time()`), so only the size publication deviates. That half is excluded from this bug.

## Trigger scenario

Unprivileged process, ramfs/tmpfs file of 8192 bytes, buffer whose first page is `PROT_NONE` (a guard page, a range another thread just `mprotect`ed, or a bad pointer):

1. `pwrite(fd, buf, 8192, 4096)` — starts inside the file, ends past EOF.
2. The copy faults at byte 0; `Vmo::write` (`vmo/mod.rs:570` → `write_anonymous_pages:690`) returns `Err`, the count is dropped by `From<(ostd::Error, usize)>` (`error.rs:209`), and `write_at` propagates `EFAULT` with `fs.rs:742` already applied.
3. `fstat` reports 12288. Reading past the old EOF returns 4096 zero bytes.

This is the counterexample's geometry exactly: `MCSysPwrite64Start(t2,"Ramfs","Complete",1,...)` with `explicitOffset=1 < fileSize=2 < plannedEnd=3`, then `MCFileOpsWriteAtCopyFaultZero(t2,...)` → `copied="Zero"`, `committed="Zero"`, `fileSize=3`.

## Developer intent

No comment, TODO or test in the tree covers the ordering. Upstream issue #711 (`EFAULT` mid-I/O, open, P4) is a different mechanism — discarded *partial* progress — and its fix would not touch either path here. Upstream PR #3297 (open draft) states the intended semantics directly: `InodeRollbackGuard` "captures the current state before fallible operations and restores it on error, with `commit` finalizing success", restoring page-cache capacity and block mappings to the captured `old_size`. It applies that guard to ext2 only; ramfs is not in scope. So the maintainers treat restore-on-write-failure as correct, and this site does not do it.

## Reproduction result

PASS at **Level 0** (public syscalls only; no failpoints, no state injection, no source patch). The Asterinas guest was built from the pristine baseline — `git checkout -- kernel/` first, `git status -- kernel/` empty, zero `tla_trace` references in `build.log`. The same binary runs on Linux tmpfs as control.

Command: `.specula-output/repro/test_bugMC-4_ramfs_size_publication.sh`

```
-- [1/3] Linux control (tmpfs /dev/shm) --
MC4_BEGIN os=linux dir=/dev/shm
CASE A pwrite64_extending_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=8192 linux_expected=8192 VERDICT=OK
CASE A lseek_end=8192
CASE A pread_past_old_eof: ret=0 nonzero_bytes=0 linux_expected_ret=0
CASE A size_after_close_reopen=8192 linux_expected=8192
CASE B pwrite64_zero_length_past_eof: ret=0 errno=0 size_before=8192 size_after=8192 linux_expected=8192 VERDICT=OK
CASE C write_o_append_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=8192 linux_expected=8192 VERDICT=OK
CASE D write_at_seeked_offset_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=16384 linux_expected=16384 VERDICT=OK
CASE E pwrite64_overlapping_eof_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=8192 linux_expected=8192 VERDICT=OK
CASE E pread_past_old_eof: ret=0 linux_expected_ret=0
MC4_SUMMARY os=linux deviations=0 failures=0

-- [2/3] Building Asterinas from the pristine baseline kernel --
baseline commit: 2cd64291cf4e11283eeabb4e4e953cb8be971cb9
kernel/ tree state (must be empty => no kernel modification):

== Asterinas guest output ==
MC4_BEGIN os=asterinas dir=/
CASE A pwrite64_extending_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=16384 linux_expected=8192 VERDICT=SIZE_GREW
CASE A lseek_end=16384
CASE A pread_past_old_eof: ret=4096 nonzero_bytes=0 linux_expected_ret=0
CASE A size_after_close_reopen=16384 linux_expected=8192
CASE B pwrite64_zero_length_past_eof: ret=0 errno=0 size_before=8192 size_after=16384 linux_expected=8192 VERDICT=SIZE_GREW
CASE C write_o_append_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=16384 linux_expected=8192 VERDICT=SIZE_GREW
CASE D write_at_seeked_offset_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=24576 linux_expected=16384 VERDICT=SIZE_GREW
CASE E pwrite64_overlapping_eof_zero_copy_fault: ret=-1 errno=14 size_before=8192 size_after=12288 linux_expected=8192 VERDICT=SIZE_GREW
CASE E pread_past_old_eof: ret=4096 linux_expected_ret=0
MC4_SUMMARY os=asterinas deviations=5 failures=0

== Side-by-side ==
CASE   OPERATION                                      LINUX      ASTERINAS
A      pwrite64_extending_zero_copy_fault             size=8192  size=16384
B      pwrite64_zero_length_past_eof                  size=8192  size=16384
C      write_o_append_zero_copy_fault                 size=8192  size=16384
D      write_at_seeked_offset_zero_copy_fault         size=16384 size=24576
E      pwrite64_overlapping_eof_zero_copy_fault       size=8192  size=12288
```

Lines demonstrating the bug: every `VERDICT=SIZE_GREW`, and `CASE A size_after_close_reopen=16384` (permanence). `CASE E` is the counterexample geometry — same actions, same order, same invariant, same code path. `CASE D` corrects a naive expectation the control caught: Linux tmpfs *does* move `i_size` to the write start offset (`pos + copied`, copied = 0), so the deviation there is that Asterinas publishes `pos + len` (24576) instead of `pos` (16384).

Cross-check against pre-existing evidence: `harness/logs/ramfs_zero_append.log` already recorded the internal publication (`kind:16` `[16384, 24576, 24576]` immediately followed by `kind:21` copy-fault-zero `[8192, 0, ...]` and `kind:33` write-fault `[0, 24576, ...]`), from an independent instrumented run.

Files: `repro/test_bugMC-4_ramfs_size_publication.c`, `repro/test_bugMC-4_ramfs_size_publication.sh`, raw logs in `repro/out_bugMC-4/`; evidence record in `confirmation/MC-4/investigation.md`.

## Recommendation

Publish the size from what was actually copied, after the copy — mirroring PR #3297's `InodeRollbackGuard` at the ramfs site:

1. Keep growing the page cache before the copy (`Vmo::write` clamps to `self.size()`, so capacity must exist first), but capture `old_size` and shrink back on error.
2. After `page_cache.write`, compute `copied = write_len - reader.remain()` and publish `max(file_size, offset + copied)` only when `write_len > 0`. A zero-length request must not touch the size at all — that is the Linux rule the control measured (cases B and D together pin it down).
3. Return `Ok(copied)` rather than `Ok(write_len)`; that also closes the ramfs half of issue #711, but the size fix is independent and must not wait for it.

Pre-`REPRODUCED` checklist:

1. **Level 0 alone triggered it — yes.** Public syscalls only (`open`/`pwrite`/`write`/`lseek`/`fstat`/`mprotect`), no failpoints, no timing help, pristine kernel.
2. Not applicable — Level 2/3 were never used.
3. **Real consumers observing the wrong outcome**: `sys_fstat`/`sys_stat`/`sys_statx` via `kernel/core/src/syscall/stat.rs:200` (`st_size` = 16384 after a write that moved nothing), and `RamInode::read_at` at `kernel/core/src/fs/fs_impls/ramfs/fs.rs:695`, which clamps to the inflated size and returns 4096 phantom zero bytes where Linux returns EOF. Both are in the captured output, not argued.
4. **Permanent.** No writeback, sync, resend or `fsck` path exists for ramfs, and the test proves it survives close/reopen (`CASE A size_after_close_reopen=16384`). Nothing masks or later corrects it.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation 2>/dev/null && ls -R | head -40 && echo "=== GUIDE ===" && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/01-investigation.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/02-reproduction.md
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running cd /tmp && command -v gh >/dev/null && timeout 120 gh issue view 711 --repo asterinas/asterinas --json number,title,state,createdAt,body,comments --jq '{n:.n...
running cd /tmp echo "=== upstream main ramfs write_at ===" timeout 120 gh api "/repos/asterinas/asterinas/contents/kernel/core/src/fs/fs_impls/ramfs/fs.rs?ref=main"...
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running cd /tmp echo "### PR 3297 ###" timeout 120 gh pr view 3297 --repo asterinas/asterinas --json number,title,state,isDraft,createdAt,body,files --jq '{n:.number...
running cd /tmp for q in "ramfs+inode+size" "tmpfs+size+write+fail" "st_size+wrong" "size+grow+EFAULT" "write+zero+length+file+size" "size+not+rolled+back"; do echo...
running cd /tmp echo "### PR/issue 3481 ###" timeout 120 gh api "/repos/asterinas/asterinas/issues/3481" --jq '{n:.number,t:.title,s:.state,pr:(.pull_request!=null),...
running cd /tmp timeout 120 gh api "/repos/asterinas/asterinas/pulls/3481/files?per_page=100" --jq '.[]|select(.filename|test("ramfs"))|.filename' 2>&1 | head echo "...
Let me check A's one rebutted sub-claim (timestamps) empirically, since the finding's summary rests partly on it.
running cat > /tmp/mc4_mtime.c <<'EOF' #define _GNU_SOURCE #include <errno.h> #include <fcntl.h> #include <stdio.h> #include <string.h> #include <stdlib.h> #include...
running D=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
I attacked MC-4 on five fronts. None landed; one backfired.

## Attacks that failed

**"The kernel wasn't pristine."** A's driver filters two untracked files out of its own `git status` printout, so I rechecked independently: `git diff --stat HEAD -- kernel/ ostd/` is empty, and the two untracked `tla_trace.rs` files are declared as modules **nowhere** (absent from both `HEAD:kernel/core/src/lib.rs` and the worktree copy) — `grep -c tla_trace build.log` → 0. The only tracked edits are `Makefile` + `test/initramfs/*`, adding one knob to build a *userspace* binary into the initramfs. Guest source is byte-identical to `repro/…_size_publication.c`; `guest.log` is a real QEMU boot.

**"The control is cherry-picked."** I recompiled A's C file and ran it myself: `deviations=0` on tmpfs *and* ext4, matching A case-for-case including the case-D quirk (`i_size` moves to the write start, never `pos + len`). That's the generic `write_end(copied=0)` rule, not a tmpfs artifact.

**"Something masks it."** `InodeHandle::write`/`write_at` (`inode_handle.rs:293-321,334-355`) just propagate with `?`; nothing in `ramfs/fs.rs` shrinks size on a write error; ramfs has no writeback/sync/fsck. Permanence is measured, not argued (`size_after_close_reopen=16384`).

**"The MC invariant over-flags."** `FileSizeMatchesProgress` (`base.tla:580`) fires only when `sizePublicationOwners = {}` and `dataOwner = NoThread` — i.e. a size still over-published *after* the write finished. That is precisely what the code does. No `PENDING REPAIR` route.

**"It's #711 / already reported."** #711 is entirely about short-count-vs-EFAULT; `i_size` never appears. My own tracker search found nothing. Then it backfired: **PR #3481** (open) *rewrites* `RamInode::write_at` and its new body keeps `inode_meta.size = new_size; … page_cache.write(offset, reader)?;` — same ordering, still no rollback. PR #3297's `InodeRollbackGuard` covers ext2 only. Upstream `main` is byte-identical at 721-756. `Novelty: NEW` stands, and the most recent upstream work on this function does not fix it.

## One correction to A (widens, not weakens)

A's blanket "the timestamp half is not a Linux deviation" holds only for the fault cases. Measured on Linux (tmpfs and ext4 agree):

```
A faulting_extending_pwrite     ret=-1 errno=14 mtime_changed=1 ctime_changed=1
B zero_length_pwrite_past_eof   ret=0  errno=0  mtime_changed=0 ctime_changed=0
```

Linux skips `__generic_file_write_iter` when `count == 0`; Asterinas' `set_mtime`/`set_ctime` at `ramfs/fs.rs:739-740` sit **outside** the `should_expand_size` guard and run unconditionally — and case B proves that path executes on the guest. Code-level only, **not measured on the guest**; label it that way if it's folded in.

## Verdict

Both bars are cleared. Reachability: Level 0, public syscalls, pristine kernel; case B (`pwrite(fd, buf, 0, 16384)` grows the file and returns success) needs no fault at all. Consequence: `st_size`, `lseek(SEEK_END)` and `read` all report bytes the file never received, permanently. I have no cited objection left.

Optional (not required): read the whole phantom range instead of a 4096-byte sink, and exercise the same function via `memfd_create`, which PR #3481 routes through this identical path.

Notes: `confirmation/MC-4/challenge_turn02_B.md`.

---

## Entry 5: Vectored I/O is not atomic on a shared open-file description

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-5/debate.md

I'll start by reading the bug-confirmation skill in full, then investigate.
running find /home/chin39/.claude -iname "*bug-confirmation*" -maxdepth 6 2>/dev/null; echo "---"; ls -la /home/chin39/.claude/skills 2>/dev/null | head -50
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running ls -la /home/chin39/.claude/skills | grep -i -E "bug|specula|confirm"; echo "=== plugins ==="; find /home/chin39/.claude -maxdepth 8 -type d -name "bug-confi...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running find /home/chin39/Documents/play/Specula -maxdepth 6 -type d -name "bug-confirmation" 2>/dev/null; echo "---"; find /home/chin39/Documents/play/Specula -maxd...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && ls -R && echo "===== guide.md =====" && cat guide.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running ls -la /dev/kvm 2>&1; echo "=== docker ==="; docker version --format '{{.Server.Version}}' 2>&1 | head -3; echo "=== images ==="; docker images | grep -i ast...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running timeout 25 gh --version 2>&1 | head -3; echo "--- auth ---"; timeout 25 gh auth status 2>&1 | head -8; echo "--- net ---"; timeout 20 curl -sS -o /dev/null -...
running cd /tmp && timeout 90 gh search issues --repo asterinas/asterinas "readv atomic" --limit 20 --json number,title,state,url 2>&1 | head -40; echo "=== writev a...
running cd /tmp && for q in "readv" "writev" "iovec" "file offset lock" "f_pos" "atomicity"; do echo "===== QUERY: $q ====="; timeout 90 gh search issues --repo aste...
running cd /tmp && echo "=== PRs: readv/writev atomic ==="; for q in "readv atomic" "writev" "readv" "FileLike readv" "vectored"; do echo "--- $q ---"; timeout 90 gh...
running cd /tmp && for n in 711 3181 1554; do echo "===== #$n ====="; timeout 60 gh issue view $n --repo asterinas/asterinas --json number,title,state,url --jq '"\(....
running cd /tmp && timeout 60 gh issue view 711 --repo asterinas/asterinas --json body --jq .body 2>&1 | head -60
running cd /tmp && for q in "readv" "writev atomic" "iovec atomic" "shared offset"; do echo "--- PR search: $q ---"; timeout 90 gh search prs --repo asterinas/asteri...
running cd /tmp && echo "===== PR 2230 ====="; timeout 60 gh pr view 2230 --repo asterinas/asterinas --json title,body,state,closedAt --jq '"\(.state) \(.closedAt)\n...
running cd /tmp && echo "===== PR 3720 ====="; timeout 60 gh pr view 3720 --repo asterinas/asterinas --json title,body,state --jq '"\(.state)\n\(.title)\n---\n\(.bod...
running cd /tmp && timeout 60 gh pr diff 3720 --repo asterinas/asterinas 2>&1 | head -80
running cd /tmp && for q in "atomic regular file" "shared file description" "dup offset race" "concurrent read offset"; do echo "--- $q ---"; timeout 90 gh search is...
running cd /tmp && echo "=== upstream main preadv.rs do_sys_readv ==="; timeout 60 gh api repos/asterinas/asterinas/contents/kernel/core/src/syscall/preadv.rs --jq '...
running cd /tmp && echo "=== recent commits touching preadv/pwritev/inode_handle ==="; timeout 60 gh api "repos/asterinas/asterinas/commits?path=kernel/core/src/sysc...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now writing the Phase 1 investigation record.
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running chmod +x /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-pro...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Level 0 reproduced. Now adding the counterexample's second conjunct (later-entry fault under-report) to cover the full invariant.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
Confirmation complete for MC-5.

- **Source**: MC (real counterexample: `spec/output/MC_hunt_finding_mc1_later_iovec_fault_bfs.out`, invariant `MCLaterIovecFaultLinearizable`, cfg `MC_hunt_finding_mc1_later_iovec_fault.cfg`)
- **Novelty**: NEW
- **Location**: `kernel/core/src/syscall/preadv.rs:156` (pristine `2cd6429`; also `preadv.rs:165`, `pwritev.rs:152/161`, `kernel/core/src/fs/file/inode_handle.rs:285-288` and `308-318`)

## Description

`do_sys_readv` / `do_sys_writev` loop over the iovec array calling the scalar `FileLike::read` / `FileLike::write` once per entry. `InodeHandle::read`/`write` take `self.offset.lock()` for exactly one backend call and drop the guard before returning, so the shared open-file-description offset is released **between** every pair of iovec entries. A competing `read`/`write`/`readv`/`writev` on the same description can therefore be granted the offset mid-vector, and the vectored call's bytes stop being one contiguous file range. Linux forbids this: `fdget_pos()` holds `file->f_pos_lock` for the whole vectored call (`FMODE_ATOMIC_POS` on regular files, `file_count > 1` after a `dup`), which is the guarantee `man 2 readv` states as "the data transfers performed by readv() and writev() are atomic".

Separately, when a **later** entry faults after positive copy progress, `Err(_) if total_len > 0 => break` discards that entry's already-deposited bytes: `readv` reports only the earlier entries while the user buffer holds more, and the shared offset advances by the reported amount only.

## Trigger scenario

1. `fd = open("/f", O_RDWR); fd2 = dup(fd)` — one open file description, two descriptors.
2. Thread A (CPU 0): `readv(fd, iov, 64)` with 64 × 4 KiB buffers.
3. Thread B (CPU 1): ordinary `read(fd2, buf, 64)` (CASE A) or `write(fd2, buf, 64)` (CASE B — the counterexample's `MCSysWriteStart` competitor) in a loop.
4. B is granted the offset mutex in one of A's 63 inter-entry windows and advances it; A's remaining entries then transfer at the moved offset.
5. A's `readv` returns a buffer whose bytes are **not** one contiguous file range; `writev` symmetrically deposits B's bytes *inside* A's vector range.

This matches the counterexample step for step: CE S10 (t2 releases the offset after entry 1) → S11–S12 (t1's `SharedWrite` acquires it, `ofdOffset` 2→4, `vectorIntervened[t2]=TRUE`) → S15 (t2 resumes at `vectorIndex=2` from the moved offset) → S19/S23 (later entry faults after positive copy; `reportedTotal=2` vs `copiedTotal=3`).

## Developer intent

`preadv.rs:159-163` and `pwritev.rs` carry a verbatim TODO: *"According to the man page … readv must be atomic, but the current implementation does not ensure atomicity. A suitable fix would be to add a `readv` method for the `FileLike` trait, allowing each subsystem to implement atomicity."* So the developers name the exact contract and the exact fix — but no `FileLike::readv` exists, no caller can opt in, and upstream `main` (fetched 2026-08-24 via `gh api`) still has the identical loop. Tracker search over open **and** closed/merged items (`readv`, `writev`, `iovec`, `readv atomic`, `writev atomicity`, `atomicity`, `f_pos`, `shared file description`, `concurrent read offset`) found nothing reporting this mechanism: `#711` is scalar mid-copy `EFAULT`, `#1554` is pipes, `#1245`/`#3720` are iovec parsing/bounds, `#2230` (merged) only changed short-count reporting. A source TODO is developer suspicion, not a filed report, so this is NEW.

## Reproduction result

PASS — Level 0 (pure black box). Test: `.specula-output/repro/test_bugMC-5_vector_atomicity.c` + `test_bugMC-5_vector_atomicity.sh`.

Command: `cd .specula-output/repro && ./test_bugMC-5_vector_atomicity.sh`

```
-- [2/3] Building Asterinas from the pristine baseline kernel --
baseline commit: 2cd64291cf4e11283eeabb4e4e953cb8be971cb9
kernel/ tree state (must be empty => no kernel modification):

== Side-by-side (VERDICT per case) ==
CASE   OPERATION                          LINUX          ASTERINAS
A      readv_vs_read                      ATOMIC         VECTOR_TORN
B      readv_vs_write                     ATOMIC         VECTOR_TORN
C      writev_vs_write                    ATOMIC         VECTOR_TORN
D      per_entry_read_loop_vs_read        VECTOR_TORN    VECTOR_TORN
E      later_iovec_fault                  RESULT_MATCHES_EFFECT RESULT_UNDERREPORTS_EFFECT

asterinas CASE A readv_vs_read: rounds=100 checked=100 ret_min=262144 ret_max=262144 noncontiguous_rounds=71 total_gaps=191 first_gap_entry=60 first_gap_bytes=64 competitor_ops=4213 competitor_bytes=269632 corrupt_rounds=0 linux_expected_noncontiguous_rounds=0 VERDICT=VECTOR_TORN
asterinas CASE B readv_vs_write: rounds=100 checked=100 ret_min=262144 ret_max=262144 noncontiguous_rounds=89 total_gaps=153 first_gap_entry=26 first_gap_bytes=1600 competitor_ops=3172 competitor_bytes=203008 corrupt_rounds=0 linux_expected_noncontiguous_rounds=0 VERDICT=VECTOR_TORN
asterinas CASE C writev_vs_write: rounds=100 checked=100 split_rounds=100 total_foreign_bytes_inside=338048 first_split_round=0 first_split_bytes=960 competitor_ops=9346 competitor_bytes=598144 linux_expected_split_rounds=0 VERDICT=VECTOR_TORN
asterinas CASE E later_iovec_fault: ret=4096 errno=0 deposited_entry0=4096 deposited_entry1=4096 deposited_total=8192 offset_after=4096 linux_expected_ret=8192 VERDICT=RESULT_UNDERREPORTS_EFFECT

linux     CASE A readv_vs_read: ... noncontiguous_rounds=0 total_gaps=0 ... VERDICT=ATOMIC
linux     CASE B readv_vs_write: ... noncontiguous_rounds=0 total_gaps=0 ... VERDICT=ATOMIC
linux     CASE C writev_vs_write: ... split_rounds=0 total_foreign_bytes_inside=0 ... VERDICT=ATOMIC
linux     CASE D per_entry_read_loop_vs_read: ... noncontiguous_rounds=100 total_gaps=2899 first_gap_entry=57 first_gap_bytes=64 ... VERDICT=VECTOR_TORN
linux     CASE E later_iovec_fault: ret=8192 errno=0 deposited_entry0=4096 deposited_entry1=4096 deposited_total=8192 offset_after=8192 linux_expected_ret=8192 VERDICT=RESULT_MATCHES_EFFECT
```

Lines demonstrating the bug: `noncontiguous_rounds=71/89` and `split_rounds=100` on Asterinas against `0` on Linux for the same program; and `CASE E ret=4096 … deposited_total=8192 … offset_after=4096` against Linux's `ret=8192 … offset_after=8192`. CASE D is the detector's positive control — replacing `readv` with the per-entry scalar loop that `do_sys_readv` performs tears on Linux too (100/100), so the CASE A/B detector is demonstrably not blind.

**Pre-REPRODUCED checklist**

1. **Level 0 or Level 1 alone? — yes.** Level 0 only: `open`, `dup`, `readv`, `writev`, `read`, `write`, `lseek`, `ftruncate`, `pread`, `mmap`, `mprotect`. No failpoint, no injected state, no sleep, no source patch. The driver reverts `kernel/` to the pristine baseline before building and prints the empty `git status -- kernel/` as proof.
2. **Level 2/3 pre-condition — not applicable**, neither was used.
3. **Real consumer observing the wrong outcome** — the userspace caller across the syscall ABI: the torn count and buffer are handed back by `do_sys_readv`'s `Ok(total_len)` at `kernel/core/src/syscall/preadv.rs:180` → `sys_readv` → `SyscallReturn::Return` (`preadv.rs:18`), and by `do_sys_writev`'s `Ok(total_len)` at `pwritev.rs:175`. The concrete consumer in the run is the test program's own scatter/gather reassembly (`repro/test_bugMC-5_vector_atomicity.c`, `check_readv_contiguous`), which receives bytes that are not a contiguous file range.
4. **Permanent, not masked.** Nothing downstream repairs it: `do_sys_readv`/`do_sys_writev` have no retry or reconciliation, and the per-entry offset lock is the only serialization on the path. CASE C leaves durable state — 338 048 foreign bytes permanently embedded inside the writev range in the file. CASE E leaves the application holding 8192 bytes while told 4096, with the offset advanced only 4096, so the next read re-delivers bytes 4096‥8191 as duplicates.

## Recommendation

Add `readv`/`writev` methods to the `FileLike` trait (the fix the source TODO already names) so one vectored call is one critical section:

- Give `InodeHandle` a vectored implementation that takes `self.offset.lock()` **once**, loops the `VmWriterArray`/`VmReaderArray` inside the guard against `file_ops.read_at`/`write_at`, and advances `*offset` by the total. That restores the Linux `f_pos_lock` semantics for `readv`/`writev`/`preadv`/`pwritev` alike.
- Default the trait method to today's per-entry loop so non-seekable subsystems keep working unchanged; only offset-aware files need the atomic path.
- Independently, fix the later-entry accounting: on a per-entry error, the bytes already transferred into that entry must be added to `total_len` and to the shared offset before breaking, so the returned value equals the bytes actually deposited (CASE E). Today `preadv.rs:167` (`Err(_) if total_len > 0 => break`) discards them.
- Add the CASE A/B/C/E checks as a regression test under `test/initramfs/src/regression/io/`; there is currently no test that exercises two threads on one shared open file description.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running find /home/chin39/.claude -type d -name "bug-confirmation" 2>/dev/null; find / -type d -name "bug-confirmation" -not -path "*/node_modules/*" 2>/dev/null | h...
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running ls /home/chin39/.claude/skills/ 2>/dev/null; ls /home/chin39/.claude/plugins 2>/dev/null | head; find /home/chin39/.claude -maxdepth 4 -iname "*bug-confirm*"...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation 2>/dev/null && ls -R . | head -60 && echo "===== SKILL.md / guide.md =====" && for f in SKILL....
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/01-investigation.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/02-reproduction.md
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Verified evidence gathered. Let me record my challenge notes.
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
I attacked MC-5 on every bar I could reach and it survived. Notes: `.specula-output/confirmation/MC-5/turn02_B.notes.md`.

## Attacks I ran, and why each failed

**"The kernel under test isn't pristine."** The driver builds with `ENABLE_SPECULA_TRACE=true` and the worktree carries two untracked `tla_trace.rs` files, so I checked whether either reaches the build. `grep -rn "mod tla_trace" worktree/kernel/` → no matches; `grep -rn "SPECULA_TRACE" worktree/Makefile` → only the two assignments (`Makefile:66`, `Makefile:119`), consumed nowhere. Neither the files nor the flag affect the built kernel. Level 0 claim holds.

**"Linux's 0/100 is a starved competitor, not `f_pos_lock`."** This one backfired into evidence *for* the finding. From `out_bugMC-5/linux.log`: CASE A `competitor_ops=2`, CASE B `93`, CASE C `100` — i.e. ~1 op per round from a tight `while(round_active) read/write(64B)` loop on tmpfs, which free-running would turn over tens of times per round. One-op-per-round is the signature of a thread parked on `f_pos_lock` for the whole vector call and getting exactly one op in after release. CASE D (same threads, same barriers, `readv` swapped for the per-entry scalar loop `do_sys_readv` actually performs) gives Linux `comp_ops=3028` and `noncontiguous_rounds=100/100`. Linux's atomicity is demonstrated positively, and the detector is provably not blind.

**"The contiguity detector can false-positive."** It can't produce these numbers spuriously: all Asterinas rounds returned the full 262144 (`ret_min=ret_max`), so no short return masquerades as a gap; a 'C'-filled competitor word decodes to `0x43434343*4 > READ_FILE_BYTES` and is counted as `corrupt`, and `corrupt_rounds=0` everywhere; and CASE A's `first_gap_bytes=64` is exactly `COMP_BYTES`, so the gap size matches the claimed mechanism quantitatively.

**"Known limitation → not a finding."** Dead end by rule. The target guidance bars reporting *the TODO* as the finding but instructs verifying the Linux-visible consequences, which A did; `phases/01-investigation.md` Step 3 says a TODO is suspicion, not a filed report, and the only allowed drop is code-review-sourced. MC-5 has a real trace (`MC_hunt_finding_mc1_later_iovec_fault_bfs.out:35`, invariant violated; `vectorIntervened[t2]=TRUE` from State 14, `MCFileOpsReadAtCopyFaultPositive(t2)` at State 19, `copiedTotal=3` vs `reportedTotal=2` at State 23).

**"Masked / transient."** No mask exists. `InodeHandle::read`/`write` lock the offset for exactly one `read_at`/`write_at` and drop the guard on return; there is no retry or reconciliation above it. CASE C leaves 338048 competitor bytes durably embedded *inside* the writev range (Linux: 0).

## Corrections A must apply (none change the verdict)

1. **Drop the "duplicates" claim in CASE E.** `ret=4096` and `offset_after=4096` are mutually consistent, so the next read correctly delivers 4096.. and nothing is double-counted. The defensible harm is narrower: the returned count disagrees with the committed effect (4096 reported vs 8192 deposited; Linux returns 8192 for the same binary).
2. **CASE E's root cause is MC-1's, and A's third fix bullet is redundant.** `test_bugMC-1_partial_read_efault.c:17-20` records MC-1's mechanism — the fallible copy returns `Err((PageFault, copied))` and every layer above drops `copied`. Fix that and `do_sys_readv` accumulates 8192, sees `writer.has_avail()`, breaks, returns 8192; CASE E vanishes without touching `preadv.rs`. The `Err(_) if total_len > 0 => break` arm is correct Linux short-I/O behaviour once the scalar layer stops swallowing `copied`. Attribute E to MC-1; MC-5's headline rests on A/B/C.
3. **Residual trace-matching gap.** `base.tla:610` fires only on the full conjunction (`vectorIntervened` ∧ later-entry positive fault). A reproduced the two conjuncts in separate runs. Both are unconditional code paths so the composition is sound, but if MC-5 is ever re-run, leave the competitor thread active during CASE E — it already exists in the program and currently idles — so one execution carries both.

The headline claim (vectored I/O is not atomic on a shared OFD) clears reachability at Level 0 on a pristine kernel with a Linux control and a positive control, and clears consequence with durable file corruption. I found no mask, no unreachable step, and no detector flaw.

---

## Entry 6: Ext2 direct write returns while an earlier submitted BIO remains live

- **Finding ID**: MC-6
- **Status**: MASKED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-6/debate.md

I'll start by reading the bug-confirmation skill in full, then investigate.
running find /home/chin39/.claude -iname "*bug-confirmation*" -maxdepth 6 2>/dev/null; echo "---"; find / -iname "*bug-confirmation*" -maxdepth 10 -not -path "*/proc...
running ls /home/chin39/.claude/skills/ 2>/dev/null | head -50; echo "=== plugins ==="; ls /home/chin39/.claude/plugins/ 2>/dev/null | head
running ls /home/chin39/.claude/skills/ | tail -30; echo "=== search bug-conf ==="; ls -d /home/chin39/.claude/skills/*bug* 2>/dev/null; echo "=== specula dir ===";...
running ls -R /home/chin39/Documents/play/Specula/skills/ 2>/dev/null | head -60
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "########## SKILL.md ##########" && cat SKILL.md && echo "########## guide.md ########...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "########## phases/01-investigation.md ##########" && cat phases/01-investigation.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "########## phases/02-reproduction.md ##########" && cat phases/02-reproduction.md &&...
I have the full skill. Starting Phase 1 investigation.
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running RUN=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running cd /tmp echo "=== issues: IoBatch ==="; timeout 60 gh search issues --repo asterinas/asterinas "IoBatch" --limit 20 --json number,title,state,url 2>&1 | head...
running cd /tmp for q in "wait_all" "write_direct_blocks" "direct io partial write" "bio pending after error" "ext2 direct write rollback" "unwaited bio" "wait_all n...
running cd /tmp echo "=== PRs mentioning IoBatch (merged/closed) ==="; timeout 90 gh search prs --repo asterinas/asterinas "IoBatch" --limit 25 --json number,title,s...
running df -T /tmp /home/chin39 2>/dev/null; echo "---"; findmnt -no FSTYPE /tmp 2>/dev/null; echo "nproc: $(nproc)"; free -g | head -2
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Now writing the reproduction test.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running F=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Now the driver script, then I'll launch the build.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
The Linux control changes the picture — let me record that and extend the test to target the distinguishing property.
running uname -r; echo "---"; cat /proc/version | head -1
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Linux control gives clean negatives on the two discriminating cases (D/E). Now launching the guest build.
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running cd /tmp echo "=== commits touching write_direct_blocks / IoBatch in upstream (via API) ===" timeout 90 gh api -X GET search/commits -f q='repo:asterinas/aste...
running cd /tmp echo "=== recent commits on io-util batch.rs ===" timeout 90 gh api -X GET 'repos/asterinas/asterinas/commits' -f path='kernel/libs/io-util/src/batch...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running cd /tmp timeout 90 gh api repos/asterinas/asterinas/commits/8acf72b4 --jq '.files[].patch' 2>&1 | head -80
running cd /tmp for i in 1 2 3; do out=$(timeout 90 gh api repos/asterinas/asterinas/commits/8acf72b4 --jq '.commit.message, (.files[].patch)' 2>&1) if [ -n "$out" ]...
running cd /tmp for q in "O_DIRECT" "direct I/O" "EFAULT partial" "partial copy fault write" "bio leak" "asynchronous write not waited"; do echo "=== issues: $q ==="...
running cd /tmp timeout 90 gh issue view 3142 --repo asterinas/asterinas --json title,body 2>&1 | python3 -c " import sys,json d=json.load(sys.stdin) b=d['body'] pri...
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirm...
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Mechanism confirmed on the target (A/B publish, C does not). The ordering harm didn't fire yet — escalating with device-queue pressure and a free-and-reallocate variant.
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
## MC-6 — Ext2 direct write returns while an earlier submitted BIO remains live

- **Source**: MC
- **Novelty**: NEW
- **Location**: `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:389` (pristine kernel; `:620` in the instrumented worktree copy)
- **Severity**: High
- **Reproduction test**: `.specula-output/repro/test_bugMC-6_direct_write_pending_bio.{c,sh}` — escalation level 1 reached (Level 0 triggers the mechanism; Level 1 fails to trigger the harm)

## Description

`write_direct_blocks` (`file.rs:383-405`) walks a direct write one *mapped device run* at a time, copying user bytes into a `BioSegment` and submitting each run asynchronously into a local `IoBatch`, which is only waited on after the loop (`file.rs:405`). A user-copy fault on a later run takes the `?` at `file.rs:389`, so the `IoBatch` is dropped with live BIOs in it. `IoBatch` (`kernel/libs/io-util/src/batch.rs:107`) has no `Drop` impl and no cancel API, and `Bio::submit` hands the request to `block_device.enqueue` *before* pushing the waiter (`bio.rs:149`) — so dropping the batch neither waits for nor cancels anything. `write_direct_at` then rolls metadata back, releases the inode lock, and `sys_pwrite64` returns `-1/EFAULT` with no byte count (`file.rs:319`, `pwrite64.rs:42`).

The unaccounted effect is live: cases A/B publish 4096 bytes after an EFAULT return, and the contiguous negative control C publishes nothing — proving publication comes exactly from the already-submitted run. But the *harm* the finding predicts ("can intervene with a later operation") did not occur: the single in-order virtio-blk virtqueue always drained the orphaned write before any later request, so the end state matches Linux ext4, which returns EFAULT with a committed prefix too.

## Trigger scenario

1. `/ext2` is the standard guest ext2 volume (`test/initramfs/src/init` mounts `/dev/vda`).
2. Fragment a victim file: one-block `O_DIRECT` write to the victim, one-block write to a spacer file, one more block to the victim. The ext2 allocator is first-fit over the group bitmap and ignores the goal hint (`block_group.rs:290`), so the victim's two logical blocks land on non-adjacent device blocks → two mapped runs.
3. `mmap` three anonymous pages, `mprotect(PROT_NONE)` the last, `pwrite(fd, buf, 8192, 0)`.
4. Run 1 copies fully and is submitted; run 2's `write_fallible` faults; `file.rs:389` returns with the batch abandoned.

This is the counterexample's exact shape: `MCSysPwrite64Start(t2,"Ext2Direct","Complete",0,"UpToDate")` → `MCBioSegmentWriteFallibleFaultZero(t2)` → `result[t2]="Fault"`, `pc[t2]="Idle"`, `pendingBios={<<t2,1,1,0,1,0>>}`, `rangeClass="InPlace"`.

## Developer intent

No commentary sanctions the behavior, and two pieces of evidence say the opposite. `batch.rs:1-64` documents the contract as *"The caller then waits for all records that were added to the batch."* The `IoRange::Hole` comment at `file.rs:393-399` states the ordering belief the error path breaks: *"Stale-read is not a concern because our inode-level lock serializes reads after this write."* Every other `IoBatch` caller (`page_cache/mod.rs:402`, `vmo/mod.rs:917`, `bio.rs:182`, `nvme/block_device.rs:923`) keeps submit and `wait_all` in one straight-line region with no fallible step between; `file.rs:383-405` is the only site that interleaves fallible work with submissions. The ktest `file_write_enospc_rollback` covers only failures *before* any submission.

Prior-report search (open issues **and** merged/closed PRs, plus upstream history of `ext2/inode/file.rs`, `io-util/src/batch.rs`, `block/src/bio.rs`): nothing reports this mechanism. Nearest non-matches: #2835 (O_DIRECT *read*), #3142 (O_DIRECT *sector-alignment* gap), #3257 (page-cache locking), PR #3509 (virtiofs O_DIRECT), and `8acf72b4`/`33acbe81` "Fix BIO completion ordering" — completion *visibility*, already in the baseline. Hence NEW.

## Reproduction result

Pristine kernel (`git checkout -- kernel/`; `git status --short -- kernel/` empty; zero `tla_trace` references in `file.rs`). `ENABLE_SPECULA_TRACE` only gates the initramfs harness derivation, not kernel code. Command: `./repro/test_bugMC-6_direct_write_pending_bio.sh`.

```
== Side-by-side (VERDICT per case) ==
CASE   SHAPE            LINUX                    ASTERINAS
A      frag_boundary    COMMIT_WITHOUT_REPORT    COMMIT_WITHOUT_REPORT
B      frag_midrun      COMMIT_WITHOUT_REPORT    COMMIT_WITHOUT_REPORT
C      contig_control   COMMIT_WITHOUT_REPORT    NO_PUBLICATION
D      pending_visible  NOT_OBSERVED             NOT_OBSERVED
E      stale_clobber    NOT_OBSERVED             NOT_OBSERVED
F      queue_pressure   NOT_OBSERVED             NOT_OBSERVED
G      free_realloc     NOT_OBSERVED             NOT_OBSERVED

asterinas CASE A frag_boundary    ret=-1 errno=14(Bad address) requested=8192 committed=4096 size=8192->8192 direct=[OO->NO] buffered=[NO] VERDICT=COMMIT_WITHOUT_REPORT
asterinas CASE B frag_midrun      ret=-1 errno=14(Bad address) requested=8192 committed=4096 size=8192->8192 direct=[OO->NO] buffered=[NO] VERDICT=COMMIT_WITHOUT_REPORT
asterinas CASE C contig_control   ret=-1 errno=14(Bad address) requested=8192 committed=0    size=8192->8192 direct=[OO->OO] buffered=[OO] VERDICT=NO_PUBLICATION
asterinas CASE D pending_visible  rounds=64 late_publication=0 already_published=64 never_published=0 setup_failed=0 first_probe_round0=B last_probe=B VERDICT=NOT_OBSERVED
asterinas CASE E stale_clobber    rounds=64 clobbered=0 intact=64 other=0 setup_failed=0 late_write_failed=0 VERDICT=NOT_OBSERVED
asterinas CASE F queue_pressure   rounds=64 clobbered=0 intact=64 other=0 setup_failed=0 background_ops=2455 VERDICT=NOT_OBSERVED
asterinas CASE G free_realloc     rounds=64 clobbered=0 intact=64 other=0 setup_failed=0 background_ops=0 VERDICT=NOT_OBSERVED
```

Escalation ladder:

- **Level 0** — A/B/C reproduce the counterexample's mechanism end-to-end through `pwrite64`/`mmap`/`mprotect` only. A publishes 4096 bytes after EFAULT; C (one contiguous run, identical faulting buffer) publishes 0. The A-vs-C delta *is* the "an earlier run was already submitted" mechanism. B commits 4096 on Asterinas vs 6144 on Linux — the partially-copied second segment is discarded, never submitted, consistent with the model.
- **Level 1** — D/E/F/G, 64 rounds each (256 total): repeated post-EFAULT probing through a separate pre-opened `O_DIRECT` fd; a subsequent *successful* `O_DIRECT` rewrite; the same under a background thread issuing 64-block direct writes (2455 completed ops keeping the queue deep); and an `ftruncate(fd,0)` free-and-reallocate cycle between the failed write and the rewrite. The orphaned BIO never landed late (`already_published=64/64`) and never reverted a later successful write (`intact=64/64`).
- **Level 2** — not applicable: the pre-condition is reached entirely through real syscalls at Level 0, so there is no state to inject.
- **Level 3** — cannot produce the trigger. The orphaned request is by definition unidentifiable to the kernel, so a delay can only be blanket; a blanket delay in `SubmittedBio::complete` or the virtio request path slows the later write equally and cannot create the ordering. Making the device complete out of order would replace a peer's semantics, not widen a window.

**Linux control (ext4, host kernel 7.1.9)**: A/B/C all `COMMIT_WITHOUT_REPORT` — Linux O_DIRECT also returns EFAULT after committing a prefix. So "EFAULT with committed bytes" is *not* a Linux-contract violation, and cannot carry the harm. D–G are clean on Linux by construction: `iomap_dio_rw` waits for every submitted BIO before returning even on the error path.

Checklist (why not `REPRODUCED`):

1. **Did Level 0/1 alone trigger it?** The *mechanism*, yes; the *harm*, no.
2. **Level 2/3 pre-condition?** Not used — nothing was injected or patched.
3. **Which real consumer observes a wrong outcome?** None demonstrated. The only user-visible outcome (`pwrite` → `-1/EFAULT` with 4096 bytes on disk) is byte-for-byte what Linux ext4 produces for the same call.
4. **Permanent or resolved/masked?** Masked. The single in-order virtio-blk virtqueue (`virtio/src/device/block/device.rs:133` → `self.queue.enqueue(bio)`) services the orphaned write before any later request from the same task, so the pending effect always settles before it can interleave. Proven by D (`already_published=64/64`) and E/F/G (`intact=64/64`).

Not `PENDING REPAIR`: the counterexample reproduced exactly, so it is not a spec/fault-model artifact, and `INVARIANT` is unsupported — `batch.rs`'s own doc and the `file.rs:398` lock-ordering comment show the implementation *does* promise to account for its I/O.

## Recommendation

Make abandoning an `IoBatch` impossible rather than fixing this one call site:

1. Give `IoBatch` a `Drop` that calls `wait_all()` (ignoring the result), so any early return still drains submitted requests. That is the smallest change and repairs every future caller too. Add a `cancel()`/`abandon()` escape hatch only if a caller genuinely needs it.
2. Independently, restructure `write_direct_blocks` so no fallible step sits between a submission and the wait: copy every run into its `BioSegment` first, then submit them all, then `wait_all`. This also stops a partially-copied run from being silently discarded (case B).
3. Once the batch is drained, decide the reported result from bytes actually committed rather than propagating the raw fault, so `pwrite` returns the short count instead of `EFAULT`. This is stricter than Linux's current O_DIRECT behavior and is the only part that changes user-visible semantics; worth doing separately.

Until (1) lands, the defect is one block-device change away from live corruption: any backend that completes requests out of order (the in-tree NVMe driver, or virtio-blk with multiple queues) removes the mask, and the extending-write path additionally frees blocks in `rollback_write` while a write to a sibling block is still in flight.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running find /home/chin39/.claude -iname "*bug-confirmation*" -maxdepth 6 2>/dev/null | head -50; echo "=== plugins ==="; find / -iname "SKILL.md" -path "*bug-confir...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running ls /home/chin39/.claude/skills/ 2>/dev/null; echo "=== plugins ==="; ls /home/chin39/.claude/plugins/ 2>/dev/null
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && ls -R . && echo "########## SKILL.md ##########" && cat SKILL.md
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "########## guide.md ##########" && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "########## 01-investigation.md ##########" && cat phases/01-investigation.md && echo...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat references/repair-request-format.md | head -80
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Now I'll write the decisive extension test — the cleanup path A never exercised, plus a run on the NVMe device that ships in the project's default QEMU config.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
using ToolSearch
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
The extending-write test hit a structural blocker worth reporting. Let me fix the layout and rerun.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
The decisive experiment finished. Let me record the evidence.
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirm...
## Challenge result: the finding survives, but two of turn 1's claims need correcting

I attacked both bars. Reachability holds; consequence still fails; and I closed the one gap in A's reproduction that could have flipped it.

### What I attacked first: A's reproduction never ran the cleanup path

The counterexample is `rangeClass="InPlace"`, where `rollback_write` returns immediately (`file.rs:206-208`). All of A's cases A–G use that shape. A's own recommendation names the untested one — *"the extending-write path additionally frees blocks in `rollback_write` while a write to a sibling block is still in flight"* — and case G is not it (it frees via a user `ftruncate` after the syscall returned, and returns the block to the same file). `phases/02-reproduction.md` is explicit that a verdict read from one path can wrongly land MASKED while the delete/cleanup path is a live REPRODUCED.

New cases J/J2 (`repro/test_bugMC-6_extend_rollback_free.{c,sh}`) run it, syscalls only, pristine kernel: an **extending** O_DIRECT pwrite whose two newly allocated blocks are non-adjacent → run 1 submitted → run 2 faults → `rollback_write(0,8192)` → `truncate_to_byte_len(0)` frees both **while run 1's BIO is live** → a different file immediately claims the orphan's block.

```
/nvme  CASE J  full_extend_xfile     rounds=32 control_ok=32 control_bad=0 freed_ok=32 clobbered=0 intact=32
/nvme  CASE J2 full_extend_pressure  rounds=32 control_ok=32 control_bad=0 clobbered=0 intact=32 background_ops=255
/ext2  CASE J  full_extend_xfile     rounds=32 control_ok=32 control_bad=0 freed_ok=32 clobbered=0 intact=32
/ext2  CASE J2 full_extend_pressure  rounds=32 control_ok=32 control_bad=0 clobbered=0 intact=32 background_ops=219
```

`control_ok=32/32` is a built-in positive control (in-place faulting write reads back `CTRL,BASE`), so the two-run shape and "run 1 published" are proven, not assumed. `statvfs` confirms the kernel really did free the block under the live write. No clobber.

### Correction 1 — the mask is not "the single in-order virtio-blk virtqueue"

The default QEMU config already attaches a second block device: `-device nvme,drive=nvme0n1` (`tools/qemu_args.sh:231-232`), ext2-formatted by `test/initramfs/Makefile:$(SSD_IMAGE)`, driven by in-tree `aster-nvme` with its own worker thread (`device/registry/block.rs:44-55`). NVMe permits out-of-order completion within a submission queue — if in-order virtio were the mask, it would let go there. It does not: A's own binary on `/nvme` reproduces the mechanism (A/B commit 4096, C commits 0) and D/E/F/G are all `clobbered=0 intact=64/64`.

What actually masks it: one FIFO staging queue (`request_queue.rs:74` push_front / `:91` pop_back, merging only strictly adjacent ranges), drained by **one** dedicated worker thread per device, plus `zero_new_blocks` (`block_ptr_tree.rs:673-694`) putting a blocking `wait_all()` on **every** block allocation. Guest submission order is total; the residual window is device-side completion reordering only, and it lost 0 times in 64×(D,E,F,G) virtio + 64×(D,E,F,G) NVMe + 32×(J,J2) on each.

### Correction 2 — the corruption variant needs a near-full block group

`BlockGroup::alloc_blocks` (`block_group.rs:275-296`) tries `alloc_consecutive(count)` and only halves `count` when that fails. While any two adjacent free blocks exist in the group, a fresh 2-block allocation is **contiguous** → one run → the fault lands before anything is submitted → no orphan at all. Cases H/H2 measure this: on a merely fragmented volume the control fails 64/64 on both devices. I had to fill the volume to ENOSPC and punch isolated singletons before the extending write produced two runs. That precondition belongs in the finding's severity narrative.

### Why not PENDING REPAIR

`NoUnaccountedPendingEffect == \A bio \in pendingBios : BioAttempt(bio) \in ActiveAttempts` (`base.tla:651-652`) is cited to `file.rs:383-405` / `batch.rs:147-164`, and `batch.rs:12-16` says verbatim: *"The caller then waits for all records that were added to the batch."* J/J2 measured the concrete violation — a block back in the free bitmap with the kernel's own unwaited write outstanding. Not a benign state, so `INVARIANT` is unsupportable.

I also re-ran the Linux control myself: ext4 O_DIRECT returns EFAULT with 4096/6144/4096 committed, so that axis is not a contract violation — and it is anyway MC-2's, which is REPRODUCED on the divergent buffered path.

### Ask of A

Keep MASKED, but amend the entry: name the mask as the single-worker FIFO staging queue plus the synchronous `zero_new_blocks` barrier (not "the in-order virtqueue"), record that it holds on NVMe too, cite J/J2 as the cleanup-path evidence, and state the allocator precondition on the write-after-free variant. Notes in `confirmation/MC-6/investigation-turn02-B.md`.

---

## Entry 7: An O_APPEND fault leaves the shared offset at EOF

- **Finding ID**: MC-7
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-7/debate.md

I'll start by reading the bug-confirmation skill in full, then investigate.
running find /home/chin39/.claude -maxdepth 4 -iname "*bug-confirmation*" 2>/dev/null; echo "---"; find / -maxdepth 8 -type d -name "bug-confirmation" 2>/dev/null |...
running ls /home/chin39/.claude/skills/ 2>/dev/null | head -50; echo "=== plugins ==="; ls /home/chin39/.claude/plugins 2>/dev/null
running ls /home/chin39/.claude/skills/ | tail -30; echo "=== search for bug-confirmation ==="; ls -d /home/chin39/.claude/skills/*bug* 2>/dev/null; find /home/chin3...
running cd /home/chin39/Documents/play/Specula 2>/dev/null && ls -a | head -40; echo "=== find bug-confirmation under Specula ==="; find /home/chin39/Documents/play/...
running find /home/chin39/Documents/play/Specula/skills/bug-confirmation -type f | head -30; echo "=== GUIDE ==="; cat /home/chin39/Documents/play/Specula/skills/bug...
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md; echo "=========== PHASE 1 ==========="; cat /home/chin39/Documents/play/Specula/ski...
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running cat /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
running cd /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress;...
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
using ToolSearch
running timeout 60 gh api -X GET search/issues -f q='repo:asterinas/asterinas O_APPEND' --jq '.total_count, (.items[] | "\(.number) [\(.state)] \(.title) \(.html_url...
running timeout 90 gh pr view 3481 --repo asterinas/asterinas --json title,state,body,mergedAt,closedAt,createdAt,files 2>&1 | head -60
running timeout 120 gh api repos/asterinas/asterinas/pulls/3481 -H "Accept: application/vnd.github.v3.diff" 2>/dev/null | awk '/^diff --git a\/kernel\/src\/fs\/file\...
running timeout 90 gh api repos/asterinas/asterinas/commits/604948581 --jq '.sha, .commit.author.date, .commit.message' 2>&1 | head -10
running for q in 'repo:asterinas/asterinas file offset EFAULT write' 'repo:asterinas/asterinas offset not restored write error' 'repo:asterinas/asterinas append offs...
running timeout 60 gh pr view 3086 --repo asterinas/asterinas --json title,state,mergedAt,body --jq '.title, .state, .mergedAt, (.body|.[0:600])' 2>&1 | head -20
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running CACHE_ROOT=${SPECULA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/specula-asterinas-regular-file}; echo "$CACHE_ROOT"; du -sh "$CACHE_ROOT"/* 2>/dev/null; echo...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Now writing the reproduction. First the C test:
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running C=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/t...
Let me first validate the C test on Linux (fast), before committing to the kernel build.
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
editing /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirm...
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running B=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running F=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
# MC-7 — An O_APPEND fault leaves the shared offset at EOF

- **Source**: MC
- **Novelty**: NEW
- **Location**: `kernel/core/src/fs/file/inode_handle.rs:314` (pristine baseline; line 361 in the trace-instrumented worktree)

## Description

`InodeHandle::write` resolves `O_APPEND` by writing EOF straight into the shared open-file-description offset (`*offset = self.path().size()`) and only then calls the fallible backend. The `?` on the next line returns the backend error with the offset still parked at EOF, and no arm restores the pre-write value. The syscall reports `-1/EFAULT` — no bytes written — while every descriptor onto that open-file description (`dup`, `dup2`, `fcntl(F_DUPFD)`, `fork`) sees the position jump. Linux resolves `O_APPEND` into the local `kiocb.ki_pos` and copies it back to `file->f_pos` only after positive progress, so a failed append never moves `f_pos`.

## Trigger scenario

Pure public-API sequence, unprivileged, no concurrency required:

1. Create a 4096-byte regular file.
2. `open(path, O_RDWR|O_APPEND)`, then `dup(fd)` — a second descriptor onto the same open-file description.
3. `lseek(fd, 0, SEEK_SET)` → shared offset 0.
4. `mmap` two anonymous pages, `mprotect` the first `PROT_NONE`, `write(fd, that_page, 4096)`. The copy-from-user faults at zero bytes; the syscall returns `-1/EFAULT`.
5. `lseek(dupfd, 0, SEEK_CUR)` and `read(dupfd, buf, 16)` observe the damage.

This instantiates the counterexample exactly: CE state 4 moves `ofdOffset` 0→2 at `ChooseAppendStart`, state 7 is `MCFileOpsWriteAtCopyFaultZero`, and states 9–10 reach `SyscallDispatch` with `reported = "Zero"` and `ofdOffset` still 2 — violating `MCSharedOffsetMatchesReported`. The harness trace `traces/ramfs_zero_append.ndjson` had already recorded the same shape from the live kernel (`ofd_offset` 0→4, `FileOpsWriteAtCopyFaultZero`, `SysWriteReturn` with `result:"Fault"`, `reported_total:0`, `ofd_offset:4`).

## Developer intent

Two `FIXME`s sit at the site (pristine `inode_handle.rs:310,312`), but they cover `O_APPEND` when `open_file` is set and concurrent-append range atomicity — neither mentions error-path offset state, and both are out of this campaign's scope. No test asserts the behaviour: `grep -rn O_APPEND test/` yields only a `F_SETFL` flag round-trip and an append-mode open of an unlinked file. Tracker search (`gh api search/issues`: `O_APPEND`, `file offset EFAULT write`, `offset not restored write error`, `append offset error write fails`, `lseek offset after failed write`) found no report of this mechanism. The nearest hit, **PR #3481 "Fix inode append and memfd seal races"**, is **open and unmerged** (created 2026-06-29, `mergedAt: null`; absent from the 2026-08-08 baseline `604948581`); it reports the *size TOCTOU*, and its refactor happens to reorder the assignment after the fallible call, which would incidentally remove this defect too. An unmerged PR about a different defect is not a report of this one — hence `NEW`, with #3481 flagged as the natural landing place for the fix.

## Reproduction result

PASS — **Level 0** (pure black-box; pristine kernel, no failpoint, no injected state, no source modification). Levels 1–3 were not needed.

Test: `repro/test_bugMC-7_append_offset_on_fault.c` + `.sh`. Command:

```
cd .specula-output/repro && ./test_bugMC-7_append_offset_on_fault.sh
```

The driver reverts `kernel/` to the baseline before building and prints the tree state; it was empty, i.e. an unmodified kernel (the two untracked `tla_trace.rs` files are not declared as modules by the pristine `lib.rs` and are never compiled).

**Asterinas guest** (`repro/out_bugMC-7/asterinas.log`):

```
MC7_SECTION ext2
MC7_BEGIN dir=/ext2
MC7_CASE A_append_zero_fault dir=/ext2 append=1 req=4096 rc=-1 errno=14 size_before=4096 size_after=4096 off_before=0 off_after=4096 off_expected=0 dupfd_read=0 dupfd_bytes=[]
MC7_BUG A_append_zero_fault shared_offset_moved off_before=0 off_after=4096 expected=0 reported=-1
MC7_BUG A_append_zero_fault consumer_sees_eof dupfd_read=0 expected=16 bytes of file data
MC7_CASE B_plain_zero_fault dir=/ext2 append=0 req=4096 rc=-1 errno=14 size_before=4096 size_after=4096 off_before=0 off_after=0 off_expected=0 dupfd_read=16 dupfd_bytes=[AAAAAAAAAAAAAAAA]
MC7_OK B_plain_zero_fault
MC7_CASE C_append_success dir=/ext2 append=1 req=4096 rc=4096 errno=0 size_before=4096 size_after=8192 off_before=0 off_after=8192 off_expected=8192 dupfd_read=0 dupfd_bytes=[]
MC7_OK C_append_success
MC7_CASE D_append_prefix_fault dir=/ext2 append=1 req=8192 rc=-1 errno=14 size_before=4096 size_after=4096 off_before=0 off_after=4096 off_expected=0 dupfd_read=0 dupfd_bytes=[]
MC7_BUG D_append_prefix_fault shared_offset_moved off_before=0 off_after=4096 expected=0 reported=-1
MC7_BUG D_append_prefix_fault consumer_sees_eof dupfd_read=0 expected=16 bytes of file data
MC7_END dir=/ext2 bugs=2
MC7_SECTION ramfs
MC7_BEGIN dir=/tmp
MC7_CASE A_append_zero_fault dir=/tmp append=1 req=4096 rc=-1 errno=14 size_before=4096 size_after=8192 off_before=0 off_after=4096 off_expected=0 dupfd_read=16 dupfd_bytes=[]
MC7_BUG A_append_zero_fault shared_offset_moved off_before=0 off_after=4096 expected=0 reported=-1
MC7_CASE B_plain_zero_fault dir=/tmp append=0 req=4096 rc=-1 errno=14 size_before=4096 size_after=4096 off_before=0 off_after=0 off_expected=0 dupfd_read=16 dupfd_bytes=[AAAAAAAAAAAAAAAA]
MC7_OK B_plain_zero_fault
MC7_CASE C_append_success dir=/tmp append=1 req=4096 rc=4096 errno=0 size_before=4096 size_after=8192 off_before=0 off_after=8192 off_expected=8192 dupfd_read=0 dupfd_bytes=[]
MC7_OK C_append_success
MC7_CASE D_append_prefix_fault dir=/tmp append=1 req=8192 rc=-1 errno=14 size_before=4096 size_after=12288 off_before=0 off_after=4096 off_expected=0 dupfd_read=16 dupfd_bytes=[PPPPPPPPPPPPPPPP]
MC7_BUG D_append_prefix_fault shared_offset_moved off_before=0 off_after=4096 expected=0 reported=-1
MC7_END dir=/tmp bugs=2
SPECULA_SCENARIO_PASS mc7
```

**Linux control, identical binary** (`repro/out_bugMC-7/linux.log`):

```
MC7_CASE A_append_zero_fault ... rc=-1 errno=14 off_before=0 off_after=0 off_expected=0 dupfd_read=16 dupfd_bytes=[AAAAAAAAAAAAAAAA]
MC7_OK A_append_zero_fault
MC7_CASE B_plain_zero_fault ... rc=-1 errno=14 off_before=0 off_after=0 off_expected=0 dupfd_read=16 dupfd_bytes=[AAAAAAAAAAAAAAAA]
MC7_OK B_plain_zero_fault
MC7_CASE C_append_success ... rc=4096 off_after=8192 off_expected=8192
MC7_OK C_append_success
MC7_CASE D_append_prefix_fault ... req=8192 rc=4096 errno=0 off_after=8192 off_expected=8192
MC7_OK D_append_prefix_fault
MC7_END bugs=0
```

Lines that demonstrate the bug: the two `MC7_BUG A_append_zero_fault` lines on `/ext2` — `rc=-1` (no bytes reported) yet `off_after=4096` where Linux gives `off_after=0`, and the dup'd descriptor's `read` returns 0 (EOF) where Linux returns 16 bytes of file data. Case B is the negative control: the same faulting buffer without `O_APPEND` leaves the offset at 0 on both kernels, isolating the append assignment. Case C confirms the success path is correct. Case D shows the same defect on the positive-prefix fault path, where Asterinas additionally returns `-1` instead of Linux's short write of 4096.

**Required checklist**

1. **Did Level 0 or Level 1 alone trigger it? — yes.** Level 0: `open`/`dup`/`mmap`/`mprotect`/`write`/`lseek`/`read` on a pristine kernel. No failpoint, no timing assistance, no concurrency.
2. Not applicable — no Level 2 or Level 3 was used.
3. **Real consumer observing a wrong outcome:** `InodeHandle::seek` → `do_seek_util(&self.offset, …)` at `kernel/core/src/fs/file/inode_handle.rs:435`, and `InodeHandle::read` at `kernel/core/src/fs/file/inode_handle.rs:287`, both of which consume the corrupted `self.offset`. In the run, `lseek(dupfd,0,SEEK_CUR)` returned 4096 instead of 0 and `read(dupfd,…,16)` returned 0/EOF on ext2 (16 NUL bytes on ramfs) instead of the file's `'A'` data.
4. **Permanent, not masked.** Nothing re-syncs the offset: `sys_write` (`kernel/core/src/syscall/write.rs:40-45`) only fires `notify::on_modify` when `write_len > 0`; the value survives until an explicit `lseek` or a later successful non-append write. Subsequent *appends* recompute EOF, so writes stay correct — which is precisely why the corruption goes unnoticed while every read and `lseek(SEEK_CUR)` on that description stays wrong. The repro proves it by reading through the dup'd descriptor after the failed write and getting the wrong answer.

## Recommendation

Publish the append position only after the backend reports non-negative progress, matching Linux's `kiocb.ki_pos` → `f_pos` ordering. Keep the resolved append position local and commit to `*offset` on the success arm only:

```rust
let mut offset = self.offset.lock();
let start = if status_flags.contains(StatusFlags::O_APPEND) && self.open_file.is_none() {
    self.path().size()
} else {
    *offset
};
let len = file_ops.write_at(start, reader, status_flags)?;
*offset = start + len;
Ok(len)
```

Upstream PR #3481 already arrives at this ordering as a by-product of moving `O_APPEND` resolution into the filesystem layer; landing it (or the minimal reorder above) closes this. A regression test belongs in `test/initramfs/src/regression/io/file_io/`: a failed `write` on an `O_APPEND` description must leave `lseek(fd, 0, SEEK_CUR)` unchanged.

Artifacts: `repro/test_bugMC-7_append_offset_on_fault.{c,sh}`, `repro/out_bugMC-7/{driver,asterinas,linux,guest,build}.log`, `confirmation/MC-7/investigation.md`.

## Debate addendum

I'll start by reading the debate index and the required skill.
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running ls -la /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && ls -R . | head -40; echo "===== SKILL.md ====="; cat SKILL.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat guide.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/01-investigation.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && cat phases/02-reproduction.md
running cat /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running S=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running timeout 90 gh pr view 3481 --repo asterinas/asterinas --json title,state,mergedAt,closedAt,updatedAt --jq '"#3481 \(.title) | state=\(.state) merged=\(.merge...
running for q in 'repo:asterinas/asterinas O_APPEND offset write fail' 'repo:asterinas/asterinas f_pos EFAULT' 'repo:asterinas/asterinas "file offset" append failed...
running timeout 90 gh api repos/asterinas/asterinas/contents/kernel/core/src/fs/file/inode_handle.rs --jq '.content' 2>/dev/null | base64 -d 2>/dev/null | grep -n -A...
running W=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Both bars checked. Let me record my audit in the shared evidence file.
running cat >> /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progr...
I read the debate index, A's full turn-1 log, and `investigation.md`, then re-verified everything myself rather than taking A's word. I attacked both bars and could not break either.

## Reachability — attacked, held

I did not trust A's "Level 0 on a pristine kernel" claim, because the worktree carries untracked `tla_trace.rs` files and the build passes `ENABLE_SPECULA_TRACE=true`. All three checks clear:

- `git diff --stat -- kernel/` is empty; `driver.log:18-19` records `baseline commit: 2cd64291…` with an empty `git status --short -- kernel/`.
- `grep -rn tla_trace --include="*.rs" kernel/` matches only the two files themselves — no `mod`, no `#[path]`, no `include!`. Dead files, never compiled.
- `ENABLE_SPECULA_TRACE` is consumed only by `Makefile:66,119` and `test/initramfs/Makefile:10,60`. It selects initramfs contents and `--init-args`; it never reaches the kernel crate.

The trigger is `open`/`dup`/`lseek`/`mmap`/`mprotect`/`write`/`read` — nothing privileged, no failpoint, no injected state. The `PROT_NONE` first page is squarely inside the campaign's declared fault model.

I re-derived the CE correspondence from the raw trace rather than from A's table: `MC_hunt_scenario_5_append_failure_bfs.out` shows `ofdOffset` 0→2 at State 4, `MCFileOpsWriteAtCopyFaultZero` at State 7, and States 7–10 holding `ofdOffset = 2`, `reported = "Zero"`, `fileSize = 2` unchanged. That is the ext2 case A shape exactly.

## Consequence — six masks hunted, none fires

| Candidate | Result |
|---|---|
| Syscall-layer restore | None. `syscall/write.rs:31-43` only remaps `EINTR`→`ERESTARTSYS`; `notify::on_modify` is gated on `write_len > 0` and touches no offset. |
| "Nothing reads it" | False. I enumerated every `self.offset` access in `inode_handle.rs`: 91-92, 136, 287 (`read`), 425/435 (`seek`→`lseek`). Two are the exact consumers the repro exercises. |
| Later re-sync | None. Nothing rewrites the offset except the next read/write/lseek — each consumes the wrong value first. |
| "O_APPEND makes the offset don't-care" | False for reads. `O_RDWR\|O_APPEND` (glibc `fopen(…,"a+")`) reads at the shared offset. ext2 case A: `read(dupfd,…,16)` → 0/EOF vs Linux's 16 bytes, with `size_after == size_before == 4096` — the file is intact, the offset is the sole cause. |
| POSIX literalism | My strongest objection, and it fails. POSIX `write()` says the offset "shall be set to the end of the file prior to each write", which pedantically could excuse parking it there. But Asterinas' contract is Linux ABI compatibility (`README.md:33,55`) and the brief makes Linux the contract. |
| "Rarely noticed ⇒ masked" | Not a mask. Append-only workloads leave the offset at EOF anyway; the `a+` pattern puts it at 0, which is the repro's setup. Unnoticed ≠ masked. |

I rebuilt `test_bugMC-7_append_offset_on_fault.c` from source and ran it on this host to check the binary isn't rigged — identical source gives `bugs=0` on Linux 7.1.9 (`off_after=0`, `dupfd_read=16`, `[AAAA…]`) and `bugs=2` on Asterinas.

## Novelty re-checked with queries A didn't run

`f_pos EFAULT`, `O_APPEND offset write fail`, `"file offset" append failed write`, `inode_handle offset append`, `write error offset advanced` — nothing reports this mechanism. PR #3481 confirmed live as `state=OPEN merged=null updated=2026-07-21`. I also fetched **current upstream master** via the contents API: `inode_handle.rs:310-318` is byte-identical to the baseline, so the defect is live on HEAD today, not a stale-baseline artifact. `NEW` stands. (Moot anyway — the known-drop pre-filter is code-review-only.)

## Two corrections I do demand to the repro write-up

Neither touches the verdict, but the entry should not overclaim:

1. **Drop the ramfs rows from the evidence.** `/tmp` case A reports `rc=-1` with `size_after=8192`, and case D `size_after=12288` — the file grew despite a failed write. That is committed-progress-without-report, a *different* mechanism. The clean demonstrator is **ext2 case A** alone.
2. **ext2 case D carries a second divergence** — Asterinas returns `-1/EFAULT` where Linux short-writes 4096. Usable as corroboration that the append assignment moves the offset, but not citable as MC-7's harm.

The headline claim — a failed `O_APPEND` write leaves the shared OFD offset at EOF, and a real consumer on that description reads the wrong data — stands on ext2 case A by itself. I have no cited objection left, so I concede.

Audit appended to `confirmation/MC-7/investigation.md` under "Turn 2 — Challenger (Agent B) adversarial audit".

---

## Entry 8: Restart consumes an errno without progress provenance

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/CR-1/debate.md

I'll start by reading the bug-confirmation skill in full.
running find /home/chin39/.claude -iname "*bug-confirmation*" -maxdepth 6 2>/dev/null; echo "---"; find / -type d -iname "*bug-confirmation*" -not -path "*/node_modu...
running ls /home/chin39/.claude/skills/ 2>/dev/null | head -50; echo "=== plugins ==="; ls /home/chin39/.claude/plugins/ 2>/dev/null | head -50
running ls /home/chin39/.claude/skills/ | tail -30; echo "=== search bug-conf ==="; ls -d /home/chin39/.claude/skills/*bug* 2>/dev/null; ls -d /home/chin39/.claude/s...
running cd /home/chin39/Documents/play/Specula 2>/dev/null && ls -a; echo "=== find skills dirs ==="; find /home/chin39/Documents/play/Specula -maxdepth 4 -type d -n...
running ls /home/chin39/Documents/play/Specula/skills/; echo "=== bug-confirmation ==="; find /home/chin39/Documents/play/Specula/skills -maxdepth 3 -iname "*bug*" -...
running find /home/chin39/Documents/play/Specula/skills/bug-confirmation -type f | sort; echo "=== SIZES ==="; du -a /home/chin39/Documents/play/Specula/skills/bug-c...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "################ SKILL.md ################" && cat SKILL.md && echo && echo "########...
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "############ phases/01-investigation.md ############" && cat phases/01-investigation.md
running cd /home/chin39/Documents/play/Specula/skills/bug-confirmation && echo "############ phases/02-reproduction.md ############" && cat phases/02-reproduction.md
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running CR=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running RUN=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running which gh 2>&1; echo "---"; timeout 25 gh api /repos/asterinas/asterinas --jq '.full_name,.pushed_at' 2>&1 | head -5
running timeout 60 gh api -X GET "search/issues" -f q='repo:asterinas/asterinas ERESTARTSYS' -f per_page=50 --jq '.total_count, (.items[] | "\(.number) [\(.state)] \...
running timeout 60 gh api /repos/asterinas/asterinas/pulls/3576 --jq '"NUM: \(.number)\nSTATE: \(.state)\nMERGED: \(.merged)\nCREATED: \(.created_at)\nUPDATED: \(.up...
running timeout 60 gh api /repos/asterinas/asterinas/pulls/3576/files --paginate --jq '.[] | "\(.status) +\(.additions)/-\(.deletions) \(.filename)"' 2>&1 | head -60
running timeout 60 gh api /repos/asterinas/asterinas/pulls/3576/files --paginate --jq '.[] | select(.filename | test("syscall/(read|write)\\.rs$|signal/(pause|poll)\...
running timeout 60 gh api /repos/asterinas/asterinas/pulls/3576/files --paginate --jq '.[] | select(.filename | test("syscall_restart.c$")) | .patch' 2>&1 | grep -n...
running for q in 'repo:asterinas/asterinas partial write signal restart' 'repo:asterinas/asterinas EINTR partial' 'repo:asterinas/asterinas SA_RESTART' 'repo:asterin...
running timeout 60 gh api /repos/asterinas/asterinas/issues/1578 --jq '"STATE: \(.state)\nCLOSED: \(.closed_at)\nTITLE: \(.title)\n---\n\(.body)"' 2>&1 | head -60
running timeout 60 gh api /repos/asterinas/asterinas/contents/kernel/src/syscall/read.rs --jq '.content' 2>/dev/null | base64 -d | sed -n '20,50p' | nl -ba -v20; ech...
running timeout 60 gh api /repos/asterinas/asterinas/contents/kernel/core/src/syscall/read.rs -H "Accept: application/vnd.github.raw" 2>/dev/null | sed -n '20,50p' |...
running timeout 60 gh api /repos/asterinas/asterinas/pulls/3576/comments --paginate --jq '.[] | "--- \(.path):\(.line // .original_line) ---\n\(.body)"' 2>&1 | head...
running CS=/home/chin39/Documents/play/Specula/case-studies; ls "$CS" 2>/dev/null | head -20; echo "=== grep ERESTARTSYS in case-studies ==="; grep -rln "ERESTARTSYS...
running ls -la /home/chin39/Documents/play/Specula/case-studies 2>&1 | head; echo "=== submodule? ==="; cat /home/chin39/Documents/play/Specula/.gitmodules 2>/dev/null
running timeout 90 gh api -X GET "search/code" -f q='repo:specula-org/specula-case-studies ERESTARTSYS' --jq '.total_count, (.items[]? | .path)' 2>&1 | head -20; ech...
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running ls -c /dev/kvm 2>&1; echo "--- docker ---"; timeout 30 docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' 2>&1 | grep -i asterinas | head; echo "---...
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
Now let me write the reproduction test.
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
running cd /tmp && mkdir -p cr1lin && timeout 300 /tmp/cr1_check /tmp/cr1lin linuxtmp 2>&1; echo "rc=$?"; echo "--- ctrl ---"; timeout 120 /tmp/cr1_check --ctrl 2>&1...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running ls /home/chin39/Documents/play/Specula/scripts/infra/ 2>/dev/null | head -20
running sed -n '1,60p' /home/chin39/Documents/play/Specula/scripts/infra/wait_for_pid.sh; echo "=== start_background ==="; sed -n '1,40p' /home/chin39/Documents/play...
running cat > /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progre...
Now launching the guest run in the background (it builds the kernel, so it takes a while):
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running CR=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running WT=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running RUN=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running timeout 20 docker ps --format '{{.ID}} {{.Status}} {{.Image}}' 2>&1 | head -5; echo "=== guest.log tail ==="; tail -20 /home/chin39/Documents/play/Specula/ru...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
Now let me record the full escalation ladder in the test file itself, then re-run so the captured output matches the final artifact.
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
running CR=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/...
running R=/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/....
# CR-1 — Restart consumes an errno without progress provenance

- **Source**: Code Review
- **Novelty**: NEW (searched the tracker; nearest prior report is PR #3576 — same lines, different defect, see below)
- **Location**: `kernel/core/src/syscall/read.rs:36-39` and `kernel/core/src/syscall/write.rs:36-39` (with `kernel/core/src/process/signal/mod.rs:54,145`, `kernel/core/src/thread/task.rs:83`)

## Description

`sys_read`/`sys_write` map any `EINTR` from the backend to `ERESTARTSYS` with no byte count attached; `handle_pending_signal` then restores the original `rax` and rewinds the instruction pointer by one `syscall` instruction, so the call replays with the identical buffer and length. `InodeHandle::read`/`write` use `?` on `file_ops.read_at/write_at`, so an error skips `*offset += len` and the shared offset stays put. The structural reading is accurate — restartability is a bare errno with no way to say "N bytes are already done" — and the sharp consequence would be `O_APPEND`, where `inode_handle.rs:311-315` recomputes `*offset = self.path().size()` on each attempt, so a replayed commit appends the payload twice.

The precondition has no producer. `grep -rn EINTR` over the pristine tree returns **zero** hits in `kernel/core/src/fs/`, `kernel/core/src/vm/`, and `ostd/src/`. Every regular-file wait is the uninterruptible `wait_until` (`vm/page_cache/cache_page.rs:319`, `comps/block/src/bio.rs:355`), never `pause_until`; user-buffer faults are `EFAULT`. `EINTR` reaches the wrapper only from pipes/sockets/TTY/inotify, and there too every `wait_events` caller returns a short count on progress and only blocks with zero bytes committed (`pipe/common.rs:406-490`, `inotify.rs:304-308`, `tty/mod.rs:204-223`), so `poller.wait()?` can only yield `EINTR` at zero progress. The scalar wrapper makes exactly one `read_at`/`write_at` call, so it has nothing to accumulate — and the vectored path next door already does encode the discrimination the finding says is missing (`preadv.rs:113-120`, `:165-169`: `Err(_) if total_len > 0 => break`), because it loops.

## Trigger scenario

Open a regular file on `/ext2` or `/tmp` with `O_APPEND`, `dup` the fd so two descriptors share one open-file description, install a `SIGUSR1` handler with `SA_RESTART`, and flood the I/O thread with signals while issuing large writes. Step 4 of the sequence — *the ext2/ramfs backend commits a positive prefix and returns `Err(EINTR)`* — is the one with no producer. Steps 1-3 and 5 are ordinary public-API operations.

## Developer intent

`error.rs:155` marks `ERESTARTSYS` "for kernel internal use only"; `signal/mod.rs:57` says it must never reach userspace. No comment, doc, or type anywhere states the "EINTR implies zero progress" contract the scalar wrapper actually relies on — that invariant is implicit. **PR #3576, "Refactor the syscall restart machnism"** (open, updated 2026-07-23) deletes these exact lines and makes `pause_*` return `ERESTARTSYS` directly; its stated defect is *which* calls get restarted ("misses some cases where a restart should occur, and causes some cases where a restart should not occur to be restarted incorrectly" — the concrete case being socket timeouts, `sock_intr_errno`). Its regression test uses only 1-byte transfers, its review comments cover epoll wording, socket-mapping duplication and a futex relative-timeout replay, and its own fix keeps restartability encoded as a bare errno. So it neither reports nor repairs CR-1's mechanism. Issue #1578 quotes `signal(7)`'s SA_RESTART list but not its partial-transfer clause. Upstream `main` at `2bcd1ae` (2026-08-24) still carries the identical `map_err`, so the baseline is current. No existing test exercises a signal against a regular-file `read`/`write`.

## Reproduction result

`repro/test_bugCR-1_restart_progress_provenance.{c,sh}`, executed three times on a **pristine** kernel (the driver runs `git checkout -- kernel/` and prints the resulting empty `git status -- kernel/`). Levels 0 and 1 reached; Level 2 inadmissible and Level 3 not applicable, both documented in the script's `== Escalation ladder ==` output.

```
== Asterinas guest output ==
CR1_SECTION ctrl
CR1_CTRL_PIPE restart=1 ret=1 errno=0 handler_hits=130 sigs_sent=130 verdict=RESTARTED
CR1_CTRL_PIPE restart=0 ret=-1 errno=4 handler_hits=2 sigs_sent=2 verdict=EINTR
CR1_SECTION ramfs
CR1_PROBE ramfs mode=0 wr_ops=48 wr_eintr=0 wr_short=0 rd_ops=48 rd_eintr=0 rd_short=0 other_err=0 sigs_sent=32342 handler_hits=326 verdict=UNINTERRUPTIBLE
CR1_APPEND ramfs iters=128 returned=8388608 size=8388608 eintr=0 fails=0 sigs_sent=23047 handler_hits=704 verdict=NO_REPLAY
CR1_OFFSET ramfs iters=128 returned=8388608 offset=8388608 size=8388608 eintr=0 fails=0 sigs_sent=23119 handler_hits=606 verdict=NO_DOUBLE_ADVANCE
CR1_SECTION ext2
CR1_PROBE ext2 mode=0 wr_ops=48 wr_eintr=0 wr_short=0 rd_ops=48 rd_eintr=0 rd_short=0 other_err=0 sigs_sent=44585 handler_hits=315 verdict=UNINTERRUPTIBLE
CR1_APPEND ext2 iters=128 returned=8388608 size=8388608 eintr=0 fails=0 sigs_sent=23595 handler_hits=596 verdict=NO_REPLAY
CR1_OFFSET ext2 iters=128 returned=8388608 offset=8388608 size=8388608 eintr=0 fails=0 sigs_sent=30249 handler_hits=782 verdict=NO_DOUBLE_ADVANCE
CR1_SECTION ext2direct
CR1_PROBE ext2direct mode=1 wr_ops=48 wr_eintr=0 wr_short=0 rd_ops=48 rd_eintr=0 rd_short=0 other_err=0 sigs_sent=20823 handler_hits=344 verdict=UNINTERRUPTIBLE
CR1_APPEND ext2direct iters=128 returned=8388608 size=8388608 eintr=0 fails=0 sigs_sent=35088 handler_hits=657 verdict=NO_REPLAY
CR1_OFFSET ext2direct iters=128 returned=8388608 offset=8388608 size=8388608 eintr=0 fails=0 sigs_sent=29955 handler_hits=664 verdict=NO_DOUBLE_ADVANCE
CR1_SECTION ext2sync
CR1_PROBE ext2sync mode=2 wr_ops=48 wr_eintr=0 wr_short=0 rd_ops=48 rd_eintr=0 rd_short=0 other_err=0 sigs_sent=38554 handler_hits=340 verdict=UNINTERRUPTIBLE
CR1_APPEND ext2sync iters=128 returned=8388608 size=8388608 eintr=0 fails=0 sigs_sent=30288 handler_hits=622 verdict=NO_REPLAY
CR1_OFFSET ext2sync iters=128 returned=8388608 offset=8388608 size=8388608 eintr=0 fails=0 sigs_sent=17513 handler_hits=619 verdict=NO_DOUBLE_ADVANCE
SPECULA_SCENARIO_PASS cr1
```

The decisive lines:

- `CR1_CTRL_PIPE restart=1 … verdict=RESTARTED` — the positive control. 130 signals landed inside one blocked `read`, and the call was silently restarted: the `read.rs:37` `EINTR ⇒ ERESTARTSYS` arm and the `signal/mod.rs:145` SA_RESTART rewind are both **live on this kernel**. `restart=0 … errno=4` proves the non-restart half. Without this, the regular-file result would be vacuous.
- `wr_eintr=0 rd_eintr=0` in all four regular-file sections — 384 large `read`/`write` calls per backend under 20k–52k `pthread_kill`s and 315–344 confirmed handler entries, across buffered, `O_DIRECT` (real bio wait) and `O_SYNC` (write-back wait). The regular-file path never hands `EINTR` to the wrapper.
- `NO_REPLAY` / `NO_DOUBLE_ADVANCE` — 128 `O_APPEND` writes through a shared open-file description give `size == returned == 8388608`, and the shared offset equals both. Asterinas matches the Linux reference (`CR1_APPEND linuxfs … NO_REPLAY`, `CR1_OFFSET linuxfs … NO_DOUBLE_ADVANCE`) line for line.

Checklist, answered against the bug rather than for it: (1) Level 0/1 did **not** trigger it. (2) The Level-2 pre-condition — a regular-file `read_at`/`write_at` that commits a prefix and returns `EINTR` — has no real-API call sequence and no counterexample step (`counterexample: null`); the only emitter is the harness-only `ReferenceFileOps` (`tla_trace.rs:729-740, 799-815`), a synthetic `Mutex<Vec<u8>>` selected by process name, i.e. a mock emitting what no real backend sends — inadmissible, and unable to show the consequence anyway since it has no `O_APPEND` growth. (3) **No** consumer observes a wrong outcome; the consequence is argued-only. (4) Not a masked bad state — the bad state is never reached, so there is no mask to name.

## Recommendation

No fix is required for correctness today, and I would not spend a patch on it as a bug. What is real is the cost the finding actually identifies: the scalar wrapper silently depends on an undocumented cross-layer invariant ("`EINTR` ⇒ zero bytes committed") that every backend currently upholds by convention alone, while the vectored path three files over encodes the same rule explicitly. Two cheap, non-behavioural steps preserve that:

1. Document the invariant where it is consumed — a comment at `read.rs:36` / `write.rs:36` stating that `EINTR` from a `FileLike` implies no committed progress, and the matching obligation on `FileOps::read_at`/`write_at` in the trait docs. A `debug_assert!` in the `wait_events` contract would make a future violation loud.
2. Track it against **PR #3576** rather than as an independent issue. That PR is already rewriting these exact lines; if the eventual design carries progress alongside restartability (the finding's suggested outcome type) instead of another bare errno, this class closes permanently. If it lands as-is, item 1 is what keeps the assumption visible.

---
