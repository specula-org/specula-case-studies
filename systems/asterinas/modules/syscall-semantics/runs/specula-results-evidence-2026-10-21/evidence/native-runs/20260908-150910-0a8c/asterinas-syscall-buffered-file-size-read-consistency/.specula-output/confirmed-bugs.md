# Confirmation Report — asterinas-syscall-buffered-file-size-read-consistency

## Final Result

Reproduced bugs: 10 = 9 NEW + 1 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 10
Dispositions: 10 total = 10 reproduced + 0 env-limited + 0 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | REPRODUCED | yes |
| 7 | MC-7 | REPRODUCED | yes |
| 8 | MC-8 | REPRODUCED | yes |
| 9 | CR-1 | REPRODUCED | yes |
| 10 | CR-2 | REPRODUCED | yes |

## Entry 1: Ramfs reads report a saved count that differs from delivered bytes

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/work...
Let me look at the PageCache read wrapper and the write path, then check upstream Asterinas for the original (non-instrumented) code.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/work...
Now let me check the syscall consumer path and look for prior build/run infrastructure in the output dir.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls -la && ls confir...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/work...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls harness/ traces/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls traces/ | grep -...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat INSTRUM...
The harness already runs the instrumented kernel under QEMU. The finding cites the existing `ramfs-2-2` guest trace. Let me examine that trace evidence and check for reusable build artifacts.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && wc -l traces/ramfs-...
running which docker qemu-system-x86_64; ls /dev/kvm 2>&1; docker info --format '{{.ServerVersion}}' 2>&1 | head -2
using ctx_execute
This is a smoking gun from a real guest run: `pread64` with N=4 cells (8192 bytes) observed EOF at S=2 cells (4096), then the extending `pwrite64` grew the file, and the read **delivered 4 cells (8192 B: `seed,t1,t1,t1`) but returned result=2 cells (4096 B)**. Let me check the build infrastructure state to plan an independent reproduction.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat build_g...
The build directory has a prebuilt kernel and initramfs. Let me verify provenance of those artifacts and understand the guest layout.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && ls; ls .specula-output/harness/buil...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/source && git log --oneline -2 2>/dev/...
Provenance verified: the prebuilt kernel was built from `source/`, whose cited files are byte-identical to my confirmation worktree. Let me study the guest init and scenario harness to build my own guest test.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src && wc -l i...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src/scenarios.c
I now have the full picture. Let me verify the build artifacts' provenance and the Docker image availability.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat run-sta...
running docker images | head -20; docker run --rm asterinas/dev:0.18.1-20260805 bash -lc 'which qemu-system-x86_64 gcc cpio mkfs.ext2' 2>&1 | tail -5
Environment is ready (reusable kernel + dev image with qemu/gcc/cpio). Before writing the repro, Phase 1 requires a developer-knowledge / known-status search on the upstream tracker.
using web_search
The page-cache locking issue #2937 / PR #2953 is the closest precedent — I need to check whether it reports THIS exact mechanism (saved read count vs delivered bytes), and whether it landed before the base revision.
using fetch_content: Summarize this issue: what exact defect(s) does it report? Does it specifically describe a read syscall returning a saved byte count that differs from the bytes actually deliver...
using fetch_content: Summarize this issue: what exact race conditions does it report? Does it describe a read syscall returning a saved byte count that differs from bytes actually delivered/copied,...
using web_search
No filed report covers this exact mechanism. Let me verify current upstream master still has the vulnerable pattern (a very recent fix would make it KNOWN-fixed).
using fetch_content: Show the read_at function for files (Inner::File / page_cache branch) in this ramfs fs.rs. Does it compute read_len from the file size BEFORE locking the page cache, then call c...
Upstream master still has the exact vulnerable pattern — no fix has landed. Phase 1 is complete. Writing the investigation record, then building the reproduction.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1/investigation.md
Now Phase 2. Writing the reproduction test (guest C program + init + runner script).
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_ramfs_saved_count.c
Let me clean up the shared-offset helper (it has an ugly cancel/rendezvous hack) and make it structurally sound.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_ramfs_saved_count.c
Now the guest init and the runner scripts.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_init.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-1_run.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro && timeout 650 b...
Reproduced decisively at Level 1. Let me capture the summary lines from the full log.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-1 && g...
All evidence is in. Here is the confirmation record.

---

## MC-1: Ramfs reads report a saved count that differs from delivered bytes

- **Source**: MC (real counterexample `spec/output/MC_hunt_s1_ramfs_bfs1.out`, invariant SuccessfulTransferAccounting)
- **Novelty**: NEW — searched upstream issues **and** merged/closed PRs. Closest reports are different mechanisms/aspects: #2937 (design proposal: writeback/locking races, no read-count defect), #2817 (ftruncate hang in `decommit_pages`), #3256 (write-path uninitialized-page leak, merged 2026-05-25), #1542 (sendfile). Nothing reports "read returns a saved count ≠ delivered bytes" at ramfs/fs.rs / vmo/mod.rs. Current upstream master still contains the exact pattern (verified via `raw.githubusercontent.com/asterinas/asterinas/main/.../ramfs/fs.rs`).
- **Location**: `kernel/core/src/fs/fs_impls/ramfs/fs.rs:704-717` (accomplices: `kernel/core/src/vm/page_cache/vmo/mod.rs:542`, `kernel/core/src/fs/file/inode_handle.rs:290`)
- **Investigation record**: `confirmation/MC-1/investigation.md`
- **Reproduction test**: `repro/test_bugMC-1_ramfs_saved_count.c` (+ `test_bugMC-1_init.c`, `test_bugMC-1_run.sh`); escalation level reached: **Level 1**
- **Guest log**: `confirmation/MC-1/repro-guest.log`

## Description

`RamInode::read_at` computes `read_len` from `self.size()` (metadata lock, immediately dropped) **before** taking the page-cache mutex, then calls `cache.read(offset, writer)` and returns the **saved** `read_len` regardless of what the cache actually copied. `Vmo::read` (vmo/mod.rs:542) caps delivery by the VMO's own page-aligned capacity at copy time and returns `Result<()>` — no count. Between the size observation and the cache-lock acquisition, a competing `ftruncate` shrink can store `vmo.size = 0` (positive return, **zero** delivered bytes), or an extending `pwrite64` can grow the cache so **more** bytes than the saved return are delivered (including the writer's fresh payload). `InodeHandle::read` (inode_handle.rs:290) advances the shared offset by the returned count. The PageCache module doc explicitly assigns metadata/IO coherence to the filesystem; ramfs does not provide it on the read path.

## Trigger scenario

Two unprivileged threads on one 4096-byte ramfs file (initramfs root is ramfs), TSC-synchronized:
- **SHRINK**: T0 `pread(fd, buf, 8192, 0)` vs T1 `ftruncate(fd, 0)` — reader observes EOF 4096, truncator wins the cache lock (`PageCache::resize` stores `vmo.size=0`), reader copies 0 bytes, returns 4096.
- **GROW**: T0 `pread(fd, buf, 8192, 0)` vs T1 `pwrite(fd, buf, 8192, 2048)` (extends to 10240) — reader observes EOF 4096, writer holds the cache lock and grows it, reader copies 8192 bytes (4 cells `seed,t1,t1,t1`), returns 4096.

## Developer intent

Issue #2937 (closed by PR #2953, which our base already includes) shows developers know page-cache locking is incomplete, but only as a design-level concern about writeback/I/O-state races — not this defect. The current `PageCache` doc (mod.rs:132-138) states the filesystem owns "the higher-level synchronization that keeps metadata, buffered I/O … coherent", i.e. EOF-vs-cache coherence is intended to be provided by ramfs, and ramfs's read path provides none. No comments/tests assert the returned-count-vs-delivery mismatch is acceptable; the pattern persists on upstream master.

## Reproduction result

**PASS — bug triggered at Level 1** (real public syscalls only; TSC rendezvous timing; no kernel modification, no failpoints, no state injection). Kernel: prebuilt instrumented image `harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf` — provenance checked: its source tree's three cited files are byte-identical to the confirmation worktree (revision 60494858). Guest run under QEMU/KVM, `-smp 2`, threads pinned to separate vCPUs:

```
MC1_REPRO scenario=grow trial=3 read_ret=4096 write_ret=8192 delivered=8192 prefix=8192 saw_writer_data=1 final_size=10240 hit=1
MC1_REPRO scenario=shrink trial=2 read_ret=4096 trunc_ret=0 delivered=0 final_size=0 hit=1
MC1_REPRO scenario=shrink-shared trial=445 read_ret=4096 delivered=0 offset_after=4096 hit=1
MC1_REPRO scenario=grow-shared trial=88 read_ret=4096 delivered=8192 offset_after=4096 hit=1
...
MC1_SUMMARY grow_hits=1 shrink_hits=1 shared_offset_hits=228
MC1_RESULT BUG_TRIGGERED
MC1_EXIT 0
```

Delivered bytes were measured by canary inspection of the destination buffer (0xA5 prefill; file payload 0x53, writer payload 0x42, zero-fill 0x00 — none can alias the canary). `scenario=shrink trial=2`: `pread64` returned **4096** with **0** bytes written into the buffer. `scenario=grow trial=3`: `pread64` returned **4096** while **8192** bytes (including the competitor's just-written data) were delivered. Shared-offset `read(2)`: 228/5000 trials misreported, each advancing the file position by the returned count (4096) with 0 or 8192 bytes delivered — a sequential reader permanently skips undelivered data. This matches the MC trace (same actions, same invariant, same root cause) and the pre-existing `traces/ramfs-2-2.ndjson` guest capture (8192 delivered / 4096 returned, `BackendReturn result=2, ioDone=4`).

### Pre-REPRODUCED checklist

1. **Level 0/1 alone triggered it — yes.** Public syscalls (`pread64`, `pwrite64`, `ftruncate`, `read`, `lseek`), two pthreads on two vCPUs, TSC rendezvous only. No kernel patch, no failpoint, no injection.
2. N/A (no Level 2/3 used).
3. **Real consumer**: any userspace caller of `read(2)`/`pread64(2)` on a ramfs file observes a return count that does not match the bytes in its buffer (observed live in the guest); the shared-offset consequence bites at `kernel/core/src/fs/file/inode_handle.rs:290` (offset advanced by undelivered bytes, observed as `offset_after=4096` with `delivered=0`).
4. **Permanent**: the misreported count is returned directly to userspace and the offset advance persists; no downstream mechanism (sync/guard/resend) corrects either.

## Recommendation

Return the number of bytes actually copied, not the size-derived precomputation: make `Vmo::read`/`PageCache::read` report copy progress (or derive it from the `VmWriter` cursor before/after `cache.read`) and clamp the return to what was delivered; alternatively hold an inode-level rwsem across size observation + cache read so EOF cannot move between the two (the ext2/exfat paths should be checked for the same pattern separately — their lock behavior must not be mixed with ramfs's).

---

## Entry 2: ExFAT reads copy beyond their reported prefix during write preparation

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
using ls
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ 2>/dev/nu...
running wc -l /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt...
running sed -n 34,120p /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/outpu...
running grep -n "^State\|pc |->" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/...
running sed -n 2023,2257p /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/ou...
Now let me examine the affected code in the worktree.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/work...
Now let me examine the page cache read path and the VMO size semantics.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/work...
Now let me compare with ext2/ramfs read paths to see how they limit the copy (the "missing read-limit" contrast).
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/work...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls harness/ 2>/dev/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat INSTRUM...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && cat harness/fixture...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls traces/raw/ 2>/d...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls traces/raw/exfat...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && sed -n 25,100p harn...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && wc -l traces/raw/ex...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && cat traces/raw/exfa...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls harness/build/ 2...
Docker and KVM are available, and there's a prebuilt kernel + images. Let me inspect the guest build/run scripts for a known-good recipe.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat run_gue...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat src/ini...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && sed -n 100,...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/work...
Let me check the prebuilt artifacts and their provenance before reuse.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && ls -la buil...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && head -20 lo...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/investigation.md
using web_search
using fetch_content: Show the full body of the function `fn read_at(&self, offset: usize, writer: &mut VmWriter) -> Result<usize>` (the buffered, non-direct one). Quote it exactly, including whether...
using fetch_content: List every issue found: number, title, state, and one-line summary. Focus on anything about exFAT reads, read_at, page cache reads beyond EOF/file size, or read length limits.
using fetch_content: List every PR found: number, title, state, merged date, and one-line summary. Focus on anything about limiting reads to file size, writer.limit, read beyond EOF, exfat/ext2/ramf...
using fetch_content: Quote the PR title, state (open/merged/closed), creation date, and the full PR description/body. What exact bug does it describe? Does it mention concurrency, concurrent writes,...
Upstream `main` is unfixed; PR #3778 is OPEN (fix-status: unfixed). Since MC-2 is MC-sourced, the code-review×known drop does not apply — proceed to Phase 2. Let me update the investigation record and set up reproduction.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && ls; echo ---; docker images | grep...
running docker images | grep -i "asterinas/dev" ; echo ---; docker images | head -20
running which qemu-system-x86_64 gcc musl-gcc cpio 2>&1; echo ---; docker run --rm asterinas/dev:0.18.1-20260805 bash -lc 'which gcc qemu-system-x86_64 cpio; gcc --v...
 
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/work...
 
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && ls applied/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat patches...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && grep -n "pu...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && sed -n 50,1...
The trace hooks are no-ops unless armed via prctl — the prebuilt kernel is compatible with a Level 0/1 repro that observes only syscall-visible behavior. Now writing the reproduction test.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-2_exfat_read_past_prefix.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/init_mc2.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/guest_build.sh
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/guest_run.sh
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-2_run.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && chmod +x .specula-output/repro/test...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && timeout 700 bash .specula-output/re...
Reproduced — 26 hits on exFAT, 0 on the ext2 control. Let me check Part B (deterministic sequential) at the head of the log.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2 && g...
Both parts reproduced. Let me verify the instrumentation didn't alter the core logic of `Vmo::read` (provenance check on the artifact I used).
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/work...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/investigation.md
All evidence is in. Final verdict record:

---

# MC-2: ExFAT reads copy beyond their reported prefix during write preparation

- **Source**: MC (real counterexample `spec/output/MC_hunt_s1_growth_exfat_bfs1.out`, invariant `SuccessfulTransferAccounting`)
- **Novelty**: KNOWN (cite: https://github.com/asterinas/asterinas/pull/3778; fix-status: unfixed) — same mechanism at the same site: `ExfatInode::read_at` hands the caller's *unlimited* `VmWriter` to `PageCache::read` while returning a count clamped to logical EOF. The PR reports the sequential manifestation; MC-2 is the concurrent manifestation (the PR review itself flags the `resize` race). Upstream `main` is still unfixed. MC-sourced, so the code-review×known drop does not apply; proceeded to reproduction.
- **Location**: `kernel/core/src/fs/fs_impls/exfat/inode.rs:652` (read_at; also :729 write_at preparation, :157-162 submit_read_bio zero-fill), `kernel/core/src/vm/page_cache/vmo/mod.rs:542` (copy bound = VMO capacity)

## Description

`ExfatInode::read_at` computes `read_len` clamped to `inner.size` (logical EOF) but passes the unlimited writer to `page_cache.read`; `Vmo::read` copies up to `min(writer.avail(), vmo.size - offset)` — the page cache's block-aligned capacity. `ExfatInode::write_at` grows `size_allocated` and the page-cache capacity during its preparation guard and publishes `inner.size` only after the whole copy phase ("Locks released here, so that file write can be parallelized"). A concurrent read in that window copies pages beyond logical EOF — zero-filled by the backend (`submit_read_bio` → `BioStatus::Zeros` for `size <= idx*PAGE_SIZE < size_allocated`) — but returns only the old, smaller `read_len`. The user buffer past the returned count is silently clobbered, violating read(2)'s contract that only the returned number of bytes is stored. ext2 does this correctly (`writer.limit(read_len)` + write lock held across the copy).

## Trigger scenario

From the CE (2048-byte cells): t1 `pwrite64(off=2, len=2)` grows allocation/capacity 2→4 cells, releases the preparation guard, begins copying; t0 `read(off=0, len=4)` observes `L=2`, computes a 2-cell result, copies 4 cells (`out=<<seed,seed,zero,zero>>`), returns 2 (`result=2, D=4`). Instantiated in the repro as: file seeded 4096 B; t1 `pwrite64(fd, buf, 2 MiB, 4096)` (extends 4096→2101248); t0 loops `pread64(fd, buf, 8192, 0)`. A pread landing in `[PageCacheResizeCapacity, ExfatWriteAtPublish)` returns 4096 while zeroing `buf[4096..8192)`.

## Developer intent

Upstream PR asterinas/asterinas#3778 (OPEN, 2026-09-02) documents exactly this defect and intent to fix: "…hand the caller's *unlimited* writer to `PageCache::read`. The page cache's size is block-aligned, so it can hold bytes beyond the file size… A read that reaches EOF therefore writes past the byte count it returns", with a Linux comparison table and the fix (`writer.clone_exclusive()` limited to `read_len`; reviewer suggests plain `writer.limit`, and explicitly warns about "a race with `resize`" — this finding's window). The exFAT resize doc ("The `size_allocated` field in inode can be enlarged, while the `size` field will not") and the page-cache ordering comment (exfat/inode.rs:138-140) confirm the window is a known byproduct, not an intended behavior; no code comment or test asserts that stores past the return value are acceptable.

## Reproduction result

**REPRODUCED at Level 0 (deterministic control) and Level 1 (the CE schedule).** Command: `timeout 700 bash .specula-output/repro/test_bugMC-2_run.sh` (QEMU/KVM guest on the prebuilt kernel of revision 6049485…; instrumentation verified passive and logic-identical; guest log `confirmation/MC-2/build/guest.log`). Real output:

```
MC2_B backend=exfat pread-across-eof off=1 ret=1 clobbered_past_ret=4094 first=1 VULNERABLE
MC2_B backend=exfat pread-at-eof    off=2 ret=0 clobbered_past_ret=4094 first=0 VULNERABLE
MC2_B backend=exfat read-across-eof off=1 ret=1 clobbered_past_ret=4094 first=1 VULNERABLE
MC2_B backend=ext2  pread-across-eof off=1 ret=1 clobbered_past_ret=0 first=-1 clean
MC2_B backend=ramfs pread-across-eof off=1 ret=1 clobbered_past_ret=4094 first=1 VULNERABLE
...
MC2_A_HIT backend=exfat t=11 iter=7 ret=4096 clobbered=4096 first=4096 bytes_at_first=00 00 00 00 00 00 00 00
MC2_A_HIT backend=exfat t=11 iter=8 ret=4096 clobbered=4096 first=4096 bytes_at_first=00 00 00 00 00 00 00 00
MC2_A_HIT backend=exfat t=36 iter=1 ret=4096 clobbered=4096 first=4096 bytes_at_first=00 00 00 00 00 00 00 00
MC2_A_SUMMARY backend=exfat trials=40 reads=19900 hits=26
MC2_A_SUMMARY backend=ext2  trials=40 reads=17202 hits=0
MC2_RESULT exfat_hits=26 ext2_control_hits=0
MC2_END BUG_REPRODUCED
```

The `MC2_A_HIT` lines demonstrate the bug: `pread64` returned 4096 (old EOF) yet 4096 bytes past the return were stored (zeros from the backend's `BioStatus::Zeros` path) — the CE's `result=2, D=4, out=<<seed,seed,zero,zero>>` in bytes. ext2 (same workload) never clobbered: negative control. Level 0 Part B reproduces PR #3778's published table verbatim (ret=0 at EOF with the whole buffer zeroed), validating the oracle.

**Pre-REPRODUCED checklist:**
1. **Level 0/1 alone — yes.** Part B is pure sequential syscalls (Level 0). Part A uses only real `pread64`/`pwrite64` on two pinned threads with a TSC rendezvous (Level 1, timing help only); no failpoints, no state injection, no source patch.
2. n/a — no Level 2/3 escalation was needed.
3. **Real consumer**: any unprivileged userspace caller of `read`/`pread64` on an exFAT file — here the guest repro process itself (UID 1000) observes its buffer corrupted past the syscall return value. Kernel site: `ExfatInode::read_at` (exfat/inode.rs:652) returns 4096 after storing 8192 bytes into the user mapping via `InodeHandle::read_at` (inode_handle.rs:327).
4. **Permanent, not masked**: the clobbered user buffer is never restored; no downstream sync/guard resolves it. The kernel-side capacity>size gap closes at publish, but the delivered-vs-reported mismatch already reached the caller.

## Recommendation

Adopt PR #3778's fix (limit the copy to the readable prefix): in `ExfatInode::read_at`, skip the page-cache read when `read_len == 0`, otherwise read through a writer limited to `read_len` (e.g. `writer.limit(read_len)` as in ext2, or `clone_exclusive` + `skip(read_len)` to keep `readv` EOF semantics). Apply the same to `RamInode::read_at`. The upstream regression `read_eof.c` covers the sequential shape; a concurrent read-vs-extending-write regression (Part A of `repro/test_bugMC-2_exfat_read_past_prefix.c`) should accompany it, since limiting the writer — not locking out `resize` — is what makes stores == reported count during write preparation.

---

## Entry 3: ExFAT stale write preparation permits false success and inconsistent extents

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s2_exfat_extent_bfs1.out
 
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s2_exfat_extent_bfs1.out
Now let me read the cited code in the worktree.
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/work...
Let me check the page_cache read/write wrappers and the exfat read path for what happens when the VMO is smaller than the logical size.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/work...
The code-level mechanism is confirmed. Now let me check the environment for build artifacts and prior harness recipes.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/work...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/ && ls /home/chin39/Do...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls $OUT/harness/ 2>/...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cat $OUT/repro/apply...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls -la $OUT/confirma...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/investigation.md
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cat $OUT/confirmatio...
A previous turn left a thorough investigation and partial Phase 2 (L1 done: not triggered in 500 trials; L3 kernel build in progress at crash). Let me verify the state of the artifacts.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3; ta...
L1 completed (500 trials, not triggered). L3 kernel build failed with E0063. Let me see the error and the scripts used.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3; gr...
The hook is applied except one `Recorder` initializer. Fixing:
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3; se...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3/kernel-src/kernel/core/src/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 && p...
Now let me find how the L3 kernel build was invoked, then resume it.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; head -30 $OUT/confir...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -l "kernel-l3\|...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls $OUT/confirmation...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cat $OUT/harness/run...
running docker ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null; echo ====; docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | head
running RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls $RUN; echo ====; ls $RUN/source 2...
 
running RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency docker run --rm -d --name specula-mc3...
Container running. Let me check the OSDK artifacts layout, then rebuild the L3 kernel.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; find $OUT/confirmati...
running RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency OUT=$RUN/.specula-output/confirmation...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; file $OUT/confirmati...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls -la $OUT/confirma...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; strings $OUT/confirm...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/guest_mc3.c
The guest test is complete and artifacts are ready. Now I'll write the run script and execute L3 and L3R.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-3_exfat_stale_prepare.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro && timeout 8m ba...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; tail -30 $OUT/confir...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -n "MC3\|panic\...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -rn "NotInclude...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; sed -n '180,215p' $O...
running docker run --rm -d --name specula-mc3-b --network=host --device=/dev/kvm \ --mount type=bind,src=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 doc...
The component-system path heuristic breaks on the directory name "kernel-src" (it trims at the first "src/"). I'll remount the same source under a name without "src" and rebuild.
running docker stop -t 2 specula-mc3 specula-mc3-b >/dev/null 2>&1; sleep 1 RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffe...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 doc...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls -la $OUT/confirma...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -rn "kernel-src...
Stale generated paths in the osdk run-base. Wiping and rebuilding:
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 rm...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cat $OUT/confirmatio...
The osdk binary embeds kernel-src paths. Cleanest fix: rename the host dir to remove "src" from the name and rebuild osdk + kernel consistently.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output docker stop -t 2 spec...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 # R...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 doc...
Kernel built. Running the L3 guest:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro && timeout 6m ba...
Bug triggered exactly as the CE predicts. Let me capture the full L3 log context and run L3R.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -v "warning: ho...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro && timeout 6m ba...
Both completion orders triggered. Updating the run script comment (dir renamed), recording Phase 2 in the investigation file, and stopping the container.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-3_exfat_stale_prepare.sh
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-3 cat...
One gap in the L1 record — let me check whether Level 0 was distinguished from Level 1.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; head -3 $OUT/confirm...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -m2 "MC3_BEGIN\...
Trial 0 (zero entry delay = pure Level 0) was benign; the 500-trial sweep covers Level 1. Ladder complete. Composing the verdict.

---

# MC-3: ExFAT stale write preparation permits false success and inconsistent extents

- **Source**: MC (real counterexample `spec/output/MC_hunt_s2_exfat_extent_bfs1.out`, config `MC_hunt_s2_exfat_extent.cfg`, invariant `SettledReadableExtent`, 28-state trace)
- **Novelty**: NEW — searched the 420-issue inventory (open+closed), the open-PR inventory, live web searches over asterinas/asterinas issues and PRs from three angles, `exfat in:title created:>2026-06-01` (14 hits, all malformed-image crashers), and recently merged PRs #3256/#2953/#3171; closest matches are the in-tree TODO at `page_cache/mod.rs:359-361` (awareness, not a filed report) and general page-cache-locking refactor discussions (#2937/#2953, different aspect). Upstream `main` re-fetched 2026-09-09: `write_at` still has the identical prepare/release/reacquire structure with no revalidation — unfixed. No report describes this mechanism at this site.
- **Location**: `kernel/core/src/fs/fs_impls/exfat/inode.rs:711-755` (`ExfatInode::write_at`; pristine numbering — cites 715/734/743/755), with `kernel/core/src/vm/page_cache/mod.rs:271` (`PageCache::resize`) and `kernel/core/src/vm/page_cache/vmo/mod.rs:571` (`Vmo::write` clamp)

## Description

`ExfatInode::write_at` runs a three-phase protocol: (P1) under the exclusive write guard, allocate clusters and `page_cache.resize(new_size, file_size)`, saving `new_size`; (P2) **release the write guard** ("Locks released here, so that file write can be parallelized"); (P3) reacquire an *upgradeable* guard, copy via `page_cache.write(offset, reader)`, then publish `inner.size = new_size` and return the full requested `write_len`. The saved `new_size` and the prepared cache capacity are never revalidated across the release/reacquire gap. A second extending writer can enter P1 in that gap and, because its own end offset is smaller, **lower** the VMO capacity (`vmo.size.store(new_cache_size)`, decommitting pages above it). The first writer's copy is then silently clamped — `Vmo::write` computes `write_len = remain().min(size().saturating_sub(offset))` and returns `Ok(())` on 0 — yet it still publishes its stale `new_size` and returns the full count. `PageCache`'s `VmIo` returns `Result<()>`, so no layer ever learns how few bytes moved.

## Trigger scenario

Two unprivileged threads `pwrite64` disjoint extending ranges of one exFAT file (seed 4096 B): t1 `pwrite(fd,'B',4096,8192)`, t0 `pwrite(fd,'A',4096,4096)`. CE order (states 4–27): t1 prepares (C→12288) and releases; t0 prepares (C→8192, **lowering** the capacity t1 prepared), copies 4096 B, publishes L=8192, returns 4096; t1 copies at 8192 with C=8192 → 0 bytes copied, publishes **L=12288**, returns **4096**. Settled: L=12288 > C=8192. Regression order: t1 publishes 12288 first, then t0 publishes its stale 8192 — the acknowledged extent [8192,12288) ends up beyond EOF.

## Developer intent

- `exfat/inode.rs` comment: *"Locks released here, so that file write can be parallelized."* — the release is deliberate for parallelism; the missing revalidation is not discussed anywhere.
- `page_cache/mod.rs:359-361` TODO (verbatim): *"This should require `&mut` to ensure that the caller holds the inode lock. However, we need to fix the exfat code first, since it does not hold the write lock when handling `write()`."* — direct in-tree acknowledgement the exFAT write path lacks write-lock coverage.
- `PageCache::resize` doc contract (mod.rs:201-214): *"The filesystem must keep that capacity synchronized with its own file size under the same inode- or file-level lock that excludes conflicting buffered I/O and resizing."* — exFAT violates this documented contract across the gap. No test asserts the current behavior.

## Reproduction result

Escalation ladder (guest program `repro/guest_mc3.c`; runner `repro/test_bugMC-3_exfat_stale_prepare.sh`; runs in QEMU/KVM, `-smp 2`, exFAT virtio-blk image, Asterinas kernel built from the instrumented worktree):

- **Level 0/1** — pure black-box + timing assistance (CPU pinning, TSC rendezvous, swept entry delay, 500 trials, unpatched kernel): `MC3_VERDICT L1 not_triggered trials=500`. Window never hit natively.
- **Level 2** — skipped: the defect is a lock-protocol race window; injecting a pre-shrunk VMO would test handling of a state, not the race; Level 3 instantiates the CE's exact real-syscall schedule, strictly stronger.
- **Level 3** — prctl-armed busy-wait inserted *only* at the CE window (after `ExfatWriteAtReleasePreparation`, before reacquire; states 8–11). No logic change, default disarmed; patch audited (`diff -r`: 3 files, hook only).

Command: `bash repro/test_bugMC-3_exfat_stale_prepare.sh both`. Output, verbatim:

```
MC3_BEGIN mode=L3 kernel-delay hook (CE order: t0 completes first)
MC3_RESULT {"level":3,"trial":0,"t0_ret":4096,"t0_errno":0,"t1_ret":4096,"t1_errno":0,"size_after":12288,"read_ret":4096,"read_errno":0,"read_bytes_changed":0,"w3_ret":4096,"w3_errno":0,"r3_ret":4096,"r3_errno":0,"r3_changed":0,"size_final":12288,"CHECK1_size_regressed_below_completed_write":0,"CHECK3_read_overreport_sentinel_survives":1,"CHECK4_persistent_false_success":1}
MC3_VERDICT L3 BUG_TRIGGERED
MC3_BEGIN mode=L3R kernel-delay hook (regression order)
MC3_RESULT {"level":3,"trial":0,"t0_ret":4096,"t0_errno":0,"t1_ret":4096,"t1_errno":0,"size_after":8192,"read_ret":0,"read_errno":0,"read_bytes_changed":0,"w3_ret":4096,"w3_errno":0,"r3_ret":4096,"r3_errno":0,"r3_changed":4096,"size_final":12288,"CHECK1_size_regressed_below_completed_write":1,"CHECK3_read_overreport_sentinel_survives":0,"CHECK4_persistent_false_success":0}
MC3_VERDICT L3R BUG_TRIGGERED
```

Demonstrated harms: (L3) t1's pwrite returned 4096 having stored **0 bytes**; settled `st_size`=12288 > C=8192; `pread64(8192,4096)` returned **4096 with 0 bytes delivered** (all 4096 `0x55` sentinel bytes survived — an in-EOF hole a correct kernel reads as zeros); a third non-racing pwrite again returned 4096/0 delivered — **permanent**. (L3R) `st_size` regressed to 8192 below t1's already-successful extent 12288 — an acknowledged write lost beyond EOF.

### Pre-REPRODUCED checklist

1. **Did Level 0/1 alone trigger it?** No — 500 timing-assisted trials on the unpatched kernel, plus the harness's native collected trace (`traces/exfat-4-14.ndjson`), produced only benign orders.
2. **Level used: 3** (timing dilation only, not state injection). No pre-condition was fabricated: the patched kernel only busy-waits at the exact CE window (states 8–11); the resulting interleaving — higher extender prepares + releases (states 4–8), lower extender's prepare lowers C 6→4 (states 9–11), higher extender zero-copies, publishes stale L, returns full count (states 22–27) — is a legal schedule of the real lock protocol, reached through the real-API sequence `pthread` + `pwrite64(fd,4096,8192)` ∥ `pwrite64(fd,4096,4096)` on one exFAT file.
3. **Real consumer**: userspace via `sys_pread64`/`sys_pwrite64` (`kernel/core/src/syscall/pread64.rs:33-41` and the symmetric pwrite64 path), which return the backend count verbatim — observed: pread returning 4096/0 delivered, pwrite returning 4096/0 stored, fstat showing size regression below a completed write.
4. **Permanent?** Yes — CHECK4 proves a fresh non-racing pwrite into the stale extent after settle again false-succeeds and the range still over-reports; no downstream mechanism (read/sync/write) ever restores C versus L (reads never resize; writes inside L skip resize). Not a mask — no safeguard fires.

## Recommendation

Hold the inode write guard across prepare and copy in `ExfatInode::write_at` (as the `PageCache` `VmIo::write` TODO already anticipates), or, if parallel copies are kept, revalidate under the reacquired guard that `vmo.size()` still covers `offset + write_len` before copying, redo preparation when it does not, and reconcile the returned count/published size with bytes actually copied. `Vmo::write`'s silent 0-byte `Ok(())` for out-of-capacity offsets should not propagate into a full-count success; publication must use `max` semantics (`inner.size = inner.size.max(new_size)`) to kill the size-regression order.

Artifacts: `confirmation/MC-3/investigation.md` (full evidence + logs), `repro/test_bugMC-3_exfat_stale_prepare.sh`, `repro/guest_mc3.c`, `repro/mc3-kernel-hook.patch`, `confirmation/MC-3/build/guest-L1.log` / `guest-L3.log` / `guest-L3R.log`.

---

## Entry 4: ExFAT successful ftruncate can retain the old logical size

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
using ls
using TaskCreate: Read cited exfat/inode.rs lines (286, 307, 1452, 1455), trace call chain from public ftruncate/resize, read the MC counterexample output file, search issue tracker/git history f...
using TaskCreate: Write repro/test_bugMC-4_* test that triggers the ExFAT ftruncate-retains-old-size bug through real APIs, execute it, walk escalation ladder.
using TaskCreate: Choose one verdict from the decision table based on evidence, write required header fields and body sections.
using TaskUpdate
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | head -5...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output && ls | gr...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output && wc -l M...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output && grep -n...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output && sed -n...
The counterexample is clear: `ftruncate(fd, 1)` on an empty exFAT file returns success (result=0) while logical size `L` stays 0. Now the code audit.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/work...
The worktree has Specula tla_trace instrumentation. Now let me read the cited code regions in full.
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/work...
Call chain confirmed: `sys_ftruncate` → `InodeHandle::resize` (inode_handle.rs:401) → exfat `Inode::resize`. Now Step 2/3: developer knowledge + known-status search.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/work...
using web_search
No existing report of this exact defect. Let me verify upstream's current exfat resize code to be sure no fix landed recently.
using fetch_content: Show the `fn resize` implementations in this file: both `ExfatInodeInner::resize` and the `Inode for ExfatInode::resize` trait method. Quote them verbatim, including any code th...
Upstream main is identical — defect unfixed, no prior report → NEW. Now let me check the existing harness infra for how to run an exFAT guest test.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls harness/ repro/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat INSTRUM...
The harness builds the real kernel and boots it in QEMU with an exFAT image. The finding mentions existing `exfat-0-10` guest receipts. Let me examine those receipts and the scenario source.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls traces/raw/ | he...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/traces/raw/exfat-0-10...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src && wc -l s...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src/scenarios.c
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && grep -rn "exfat-0-1...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && sed -n '720,725p' h...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && awk 'NR>=720 && NR<...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && sed -n '720,900p' h...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat run.sh;...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && ls -la buil...
Build artifacts exist (kernel ELF, fs images). The instrumentation is documented as passive trace hooks only — compatible with a Level 0 black-box syscall repro, and it will even emit `ExfatResizeAllocation` receipts as bonus evidence. Let me verify the environment (docker, image, KVM).
running docker info --format '{{.ServerVersion}}' 2>&1 | head -2; docker image inspect asterinas/dev:0.18.1-20260901 --format '{{.Id}}' 2>&1 | head -1; ls -la /dev/k...
running docker image inspect asterinas/dev:0.18.1-20260901 --format '{{.Id}}' ; docker run --rm asterinas/dev:0.18.1-20260901 bash -c 'which qemu-system-x86_64 mkfs....
Docker image unavailable (TLS failure on pull). The built kernel + images exist locally; I need QEMU on the host. Let me search.
running ls /nix/store/ 2>/dev/null | grep -i "qemu" | head; ls /run/current-system/sw/bin/ | grep -i -E "qemu|mkfs" | head; find /nix/store -maxdepth 3 -name "qemu-s...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/build && ls -l...
running ls /nix/store/66wv70warnqxr0wsi8ilj9h95cmmrdx1-exfat-1.4.0/bin 2>/dev/null; ls /nix/store/863pcxhb3jxycvgp3c9gny14hv0kbbq2-exfat-1.4.0/bin 2>/dev/null; ls -d...
All runtime pieces available: QEMU (nix store), mkfs.exfat, the built kernel ELF, and existing fs images. Phase 1 evidence is complete. Writing `investigation.md`, then Phase 2.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/investigation.md
using TaskUpdate
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running chmod +x /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC...
Host gcc lacks a static libc. Let me find a musl/static-capable compiler in the nix store, or fall back to raw syscalls without libc.
running ls -d /nix/store/*musl* 2>/dev/null | grep -v drv | head -5; ls -d /nix/store/*gcc*static* 2>/dev/null | grep -v drv | head; find /nix/store -maxdepth 4 -nam...
running ls /nix/store/yj1pjc2syqq4gn6gr9jjda2sxhlhaqnk-glibc-2.42/lib/ | grep -E "crt1|crti|crtn" ; ls -d /nix/store/*tinycc*/bin 2>/dev/null | grep -v drv; gcc -pri...
Static linking works with `-B/-L` pointing at the glibc with `libc.a`. Updating the script.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running timeout 10m bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/te...
running ls /nix/store/dzyfajlzhgizm8xwxnxchjzls1xs1vkd-exfatprogs-1.3.2/sbin/ 2>/dev/null; /nix/store/dzyfajlzhgizm8xwxnxchjzls1xs1vkd-exfatprogs-1.3.2/sbin/mkfs.exf...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running timeout 10m bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/te...
The guest panicked early. Let me inspect the log start.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc4 && head...
adapter error: Request aborted [stall-watchdog-retry] provider returned error; treating stalled provider stream as retryable.
Kernel boots but can't find `/init` in my initramfs. Comparing my cpio entry names with the working harness one.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && cpio -it < repro/wo...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && sed -n 25,60p confi...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/work...
The harness initramfs includes `dev/proc/tmp/...` directory entries; `device::init_in_first_process` likely resolves `/dev`. Adding them.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running rm -rf /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc4 &&...
Init started but printed nothing — likely stdout buffering or an early hang. Adding unbuffered step markers and rerunning with a shorter timeout.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running timeout 5m bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/tes...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc4 && grep...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src && grep -n...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src && sed -n...
Receipts need arming (`prctl(0x53504543)`) and draining per thread. Adding that to the test for independent in-kernel corroboration.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running timeout 5m bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/tes...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running timeout 5m bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/tes...
All cases now carry in-kernel receipts. Fixing the cosmetic final grep pattern (escaping bug) and doing the final clean run for the record.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running grep -n "ExfatResizeAllocation receipts" -A1 /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consiste...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc4 && grep...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running timeout 5m bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/tes...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-4_exfat_resize.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && timeout 5m bash rep...
Reproduction complete and deterministic. Let me pin exact line numbers for the report, then write the verdict.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/work...
using TaskUpdate
# MC-4: ExFAT successful ftruncate can retain the old logical size

- **Source**: MC (real counterexample: `spec/output/MC_hunt_s3_extend_zero_exfat_bfs1.out`, invariant `SuccessfulResizeContract`)
- **Novelty**: NEW (searched asterinas/asterinas issues + recently merged/closed PRs — nearest are #2817 VMO decommit hang, PR #639 original exFAT addition, PR #3413 O_TRUNC permission; none reports this mechanism. Upstream `main` `exfat/inode.rs` resize logic is byte-identical and unfixed — verified via raw.githubusercontent fetch)
- **Location**: `kernel/core/src/fs/fs_impls/exfat/inode.rs:293` (inner resize; size assigned only in the `Less` branch at :315) and `kernel/core/src/fs/fs_impls/exfat/inode.rs:1469` (public `Inode::resize`, the ftruncate entry)

## Description

`ExfatInodeInner::resize` is documented to enlarge `size_allocated` while "the `size` field will not" — it sets `self.size = new_size` only in the cluster-count-decreases branch. That is correct for its in-`write_at` use (write publishes `size` itself at inode.rs:763), but the **public** `Inode::resize` used by `sys_ftruncate` delegates to this helper and never publishes `size` either; it also resizes the page cache only when shrinking. Result: a successful `ftruncate` extension leaves the logical size at the old value (0 for an empty file), and a same-cluster shrink leaves it at the old (larger) value, while the syscall returns 0.

## Trigger scenario

Single-threaded, no race: `open(O_CREAT|O_TRUNC|O_RDWR)` on exFAT → `ftruncate(fd, 1)` (or 8192) → `fstat`/`pread`. Matches the CE step `ftruncate(0, 0→1)` exactly: allocation runs (`A=1, clusters=1`), `BackendReturn` Ok, `L` stays 0.

## Developer intent

The helper's comment (inode.rs:291-292) sanctions not publishing size *for the helper*; nothing sanctions the public ftruncate path skipping it. `read_at` (:653-662) clamps reads at `inner.size`, `metadata()` (:1522) reports `inner.size` — both are real consumers of the stale value. ext2 publishes size correctly (control).

## Reproduction result

**Level 0 (pure black-box)** sufficed. Test: `repro/test_bugMC-4_exfat_resize.sh` (self-contained: builds a static guest init, fresh ext2/exFAT images, boots the existing instrumented kernel ELF under host QEMU/KVM — Docker image unavailable due to registry TLS failure, so artifacts were reused directly; instrumentation is passive trace hooks only). Command: `bash repro/test_bugMC-4_exfat_resize.sh`. Full log: `confirmation/MC-4/repro-output.txt`.

```
MC4CASE /exfat/mc4a  before=0    ftruncate(1)=0    errno=0 st_size=0    pread=0
MC4BUG  /exfat/mc4a:  ftruncate(1) succeeded but st_size=0
MC4CASE /exfat/mc4a2 before=0    ftruncate(8192)=0 errno=0 st_size=0    pread=0
MC4CASE /exfat/mc4b  before=4096 ftruncate(8192)=0 errno=0 st_size=4096 pread=4096
MC4CASE /exfat/mc4c  before=4096 ftruncate(2048)=0 errno=0 st_size=4096 pread=4096
MC4CASE /ext2/mc4a   before=0    ftruncate(8192)=0 errno=0 st_size=8192 pread=8192
MC4CASE /ext2/mc4c   before=4096 ftruncate(2048)=0 errno=0 st_size=2048 pread=2048
MC4VERDICT BUG bugs=8
```

In-kernel receipts from the same run (post-helper `[size, size_allocated, clusters]`):
`ExfatResizeAllocation v=[0,1,1]`, `v=[0,8192,2]`, `v=[4096,8192,2]`, `v=[4096,2048,1]` — size stale in every exFAT case, matching the CE state `L=0, A=1, clusters=1` and the pre-existing exfat-0-10 harness receipts (`v=[4096,2048,1]`, `v=[4096,8192,2]`, `SPECULA_END {"size":4096}`).

Consequences demonstrated after the successful syscall: fstat reports the wrong size (0/4096 instead of 1/8192/2048); extended zero-filled regions are unreadable (pread returns 0/4096 instead of 8192); and on same-cluster shrink, **2048 truncated-away bytes remain readable** (pread returns 4096 after ftruncate(2048)).

**Pre-REPRODUCED checklist:** (1) **yes** — Level 0 alone, public syscalls, single thread, no timing help. (2) n/a. (3) Real consumers: `ExfatInode::metadata` (inode.rs:1522) → user `fstat`; `ExfatInode::read_at` (inode.rs:662) → user `read`/`pread`. (4) **Permanent** — the wrong `inner.size` persists after the syscall; no downstream mechanism republishes it (only a future `write_at` would, as its own side effect).

## Recommendation

In `Inode for ExfatInode::resize` (inode.rs:1469), publish the logical size on success: after `inner.resize(new_size, &fs_guard)?`, set `inner.size = new_size` (and grow the page-cache bound on extension, symmetric with the shrink branch), so ftruncate honors the POSIX size contract for both extension and same-cluster shrink. Keep the inner helper's allocation-only semantics for `write_at`.

---

## Entry 5: ExFAT regrown holes can read the subject's old backing bytes

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
using TaskCreate: Code audit of cited exfat files, trace call chain, construct trigger scenario, developer-knowledge search, known-status search. Write investigation.md.
using TaskCreate: Write repro/test_bugMC-5_*, execute it through escalation ladder, decide verdict per decision table, write final response with header fields and VERDICT line.
using TaskUpdate
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | head -50
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | grep -i s3
running wc -l /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt...
running head -80 /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_h...
running grep -n "State [0-9]*:" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/s...
running grep -n "HoleZeros\|violated" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-ou...
Now let me examine the final state of the trace and the counterexample detail:
running sed -n '5434,5647p' /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/...
The counterexample is clear: `ftruncate(fd,0)` → `pwrite64(fd, 2 bytes @ offset 4)` → `pread64(fd, 0, 2)` returns `"seed","seed"` (old backing bytes) instead of zeros, violating HoleZeros. Now the code audit:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
The worktree has Specula tracing instrumentation but core logic is unchanged. Let me read the cited code in the instrumented worktree:
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/fs...
Now let me examine the page-cache side — how `write_at` grows the page cache and how holes are handled on read:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/vm...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/vm...
Now let me check the write path at the syscall layer — `inode_handle.rs` (an anchor file):
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/fs...
The mechanism is confirmed at code level. Key facts:

1. `Inode::resize(0)` (inode.rs:1469): `page_cache.resize(0, old)` decommits all cache pages; `inner.resize` → `remove_clusters_from_tail` (fat.rs:350) just marks clusters free in the bitmap — backing bytes are never erased.
2. `write_at` extending path (inode.rs:745): `page_cache.resize(new_size, file_size)` on extension only zero-fills up to the old partial page boundary (mod.rs:258-263: `new_file_size > old_file_size && !old_file_size.is_multiple_of(PAGE_SIZE)` — with old size 0, nothing is zeroed); full-page gaps stay `Uninit`.
3. Read of a hole page below logical EOF → `submit_read_bio` (inode.rs:148): zeros only when `inner.size <= idx * PAGE_SIZE`; a hole below EOF is loaded from disk → stale bytes.
4. `alloc_cluster_from_empty` (fat.rs:199-215) searches from `EXFAT_FIRST_CLUSTER` — the just-freed clusters are reclaimed deterministically on a fresh image.

Let me check the ext2 contrast and existing exFAT tests/harness:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
running which cargo-osdk qemu-system-x86_64 rustup cargo 2>&1; rustup toolchain list 2>/dev/null | head
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/ && ls /home/chin39/Do...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/ 2>/dev/null |...
running which qemu-system-x86_64; ls /nix/store/ 2>/dev/null | grep -i qemu | head -5; command -v qemu-kvm; ls /run/current-system/sw/bin/ | grep -i qemu | head
Sibling repro tests exist for other exFAT findings, meaning a working harness exists. Let me inspect the harness (shared infrastructure, intended for reuse):
running H=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; cat $H/INSTRUM...
running H=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; cat $H/run.sh;...
running H=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; cat $H/run_gue...
Docker works. Let me see how the guest init mounts the filesystems:
running H=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; sed -n 1,120p...
Docker and the harness are usable. Let me check the run directory layout and how `source` maps to my worktree, plus verify the sibling runs' environment:
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls $R | head; ls -la $R/source 2>/dev/...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; cd $R/source && git log --oneline -1 2...
The worktree matches `/work/source` exactly for the kernel. Existing build artifacts can be reused — I only need a new initramfs with my guest test. Verify provenance of the built kernel:
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls -la $R/.specula-output/harness/buil...
Build artifacts are current and a guest run succeeded. Verify the control backends (ext2/ramfs) had no HoleZeros violation — that pins this as exFAT-specific:
running S=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output; for f in M...
ext2/ramfs fully explored with no violation — exFAT-only, matching the code analysis. Now Phase 1 Step 2: developer-knowledge search.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; cd $R/baseline.git && git log --onelin...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls $R/baseline.git | head; git -C $R/b...
No local git history — single squashed export. Search upstream Asterinas for prior reports (issues + recently merged/closed PRs) on this exact mechanism:
running curl -s "https://api.github.com/search/issues?q=repo:asterinas/asterinas+exfat+truncate" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); [...
running curl -s "https://api.github.com/search/issues?q=repo:asterinas/asterinas+exfat+hole+OR+stale+OR+zero" 2>/dev/null | python3 -c "import json,sys; d=json.load(...
running cd /tmp && curl -s -o gh1.json "https://api.github.com/search/issues?q=repo:asterinas/asterinas+exfat+truncate&per_page=20"; curl -s -o gh2.json "https://api...
Two candidates need checking — issue #3604 (exFAT xfstests gaps) and PR #3778 (limit page-cache reads to file size in ramfs and exfat, touches the cited `submit_read_bio` site):
running cd /tmp && curl -s -o pr3778.json "https://api.github.com/repos/asterinas/asterinas/pulls/3778"; curl -s -o i3604.json "https://api.github.com/repos/asterina...
running cd /tmp && curl -s -o gh3.json "https://api.github.com/search/issues?q=repo:asterinas/asterinas+exfat+extend+OR+extending+OR+append+zero&per_page=20"; curl -...
running cd /tmp && curl -s -o i3142.json "https://api.github.com/repos/asterinas/asterinas/issues/3142"; curl -s -o commits_exfat.json "https://api.github.com/repos/...
running cd /tmp && curl -s -o exfat_master.rs "https://raw.githubusercontent.com/asterinas/asterinas/master/kernel/core/src/fs/fs_impls/exfat/inode.rs" && curl -s -o...
running cd /tmp && python3 - <<'EOF' import re def grab(path, fname, startpat, endpat): src = open(path).read() s = src.find(startpat) if s == -1: return None e = sr...
`write_at` is byte-identical between the pinned revision and upstream master. Check `submit_read_bio` and upstream `PageCache::resize` too:
running cd /tmp && python3 - <<'EOF' import re for tag, path in (('PINNED','exfat_pinned.rs'), ('MASTER','exfat_master.rs')): src = open(path).read() m = re.search(r...
running cd /tmp && curl -s -o gh5.json "https://api.github.com/search/issues?q=repo:asterinas/asterinas+specula&per_page=30"; python3 - <<'EOF' import json d = json....
Only PR #3778 (different mechanism) cites Specula. Verify the finding's cited line numbers against the pinned upstream files:
running cd /tmp && curl -s -o fat_pinned.rs "https://raw.githubusercontent.com/asterinas/asterinas/604948581512d83734377974d4c34adb4530f2d7/kernel/core/src/fs/fs_imp...
All cited lines check out. Now let me look at the harness's init.c for the guest exit mechanism, then write my reproduction:
running H=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; sed -n '1,80p'...
Let me verify `find_next_unused_cluster_range` is first-fit (deterministic reuse) and check the bitmap free path:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/fs...
First-fit confirmed — deterministic reuse. Phase 1 evidence is complete. Writing `investigation.md`:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/investigation.md
using TaskUpdate
Now Phase 2 — Level 0 reproduction. Write the guest test program:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_exfat_regrown_hole.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_init.c
Fix a stray comment I left in the init file, then write the run script:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_init.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_run.sh
running chmod +x /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC...
No output at all — debug:
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls -la $R/.specula-output/repro/work_m...
running cat /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc5/build.log
My earlier edit dropped a comma. Fix and rerun:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_init.c
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && timeout 400 bash re...
running grep -a -A25 "panic" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repr...
running sed -n '25,55p' /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmat...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/in...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/work...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/work_mc5 && cpio...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-5/worktree/kernel/core/src/in...
The harness pre-creates directories in the initramfs root (`dev proc tmp ramfs ext2 exfat`) — the kernel's first-process device init resolves paths there; my archive lacks them. Fix the run script:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-5_run.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && timeout 400 bash re...
**REPRODUCED at Level 0.** exFAT hole returned all 8192 stale bytes with full seed-pattern match on both pages; ext2/ramfs controls clean. Let me capture the complete guest output for the record:
running grep -a -E "MC-5|MC5|\[ext2\]|\[ramfs\]|\[exfat\]" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-co...
All evidence is in. Final verification against the REPRODUCED checklist before writing the verdict:
running docker -H unix:///var/run/docker.sock ps -a --filter name=specula-mc5 --format '{{.Names}}' | wc -l; R=/home/chin39/Documents/play/Specula/runs/20260908-1509...
using TaskUpdate
## MC-5: ExFAT regrown holes can read the subject's old backing bytes

- **Source**: MC (real counterexample `spec/output/MC_hunt_s3_holes_exfat_bfs1.out`, invariant `HoleZeros`)
- **Novelty**: NEW — searched the asterinas/asterinas tracker (open *and* closed/merged issues & PRs: `exfat truncate`, `exfat stale/hole/zero`, `exfat extend/append zero`, `specula`, tracking issues #3142/#3604). No report of this mechanism at this site. Closest neighbor, PR #3778, is a different mechanism (read-past-EOF clobbering the caller buffer) in the same file. `write_at`, `submit_read_bio`, and `PageCache::resize` are byte-identical between the pinned revision and upstream master today → unfixed upstream.
- **Location**: `kernel/core/src/fs/fs_impls/exfat/inode.rs:154` (hole page below logical EOF is loaded from disk, `Zeros` only when `inner.size <= idx*PAGE_SIZE`), with `inode.rs:743` (EOF published across the untouched hole), `fat.rs:208` (from-empty allocation is first-fit from `EXFAT_FIRST_CLUSTER`), `fat.rs:364` (truncate frees clusters in the bitmap without erasing backing bytes)

## Description

On exFAT, `ftruncate(fd, 0)` decommits all page-cache pages (`PageCache::resize(0, old)`) and frees the file's clusters via the allocation bitmap only — the on-disk bytes are never erased (`fat.rs:364`). A later extending `pwrite64` reallocates clusters through `alloc_cluster_from_empty`, whose first-fit search starts at `EXFAT_FIRST_CLUSTER` (`fat.rs:208`, `bitmap.rs:119`), deterministically reclaiming the just-freed clusters; `PageCache::resize(new, 0)` zero-fills nothing because old EOF is page-aligned (`page_cache/mod.rs:258`), and only the written tail page is committed before `inner.size` is published (`inode.rs:743`). A subsequent `pread64` of the in-EOF hole hits `submit_read_bio`, which returns `Zeros` only for pages fully beyond logical size (`inode.rs:154`) and otherwise reads the mapped cluster from disk — delivering the file's own pre-truncation bytes as hole contents. exFAT has no sparse-file representation, so unlike ext2 (gap blocks stay unmapped → holes read zeros) or ramfs (no backend), the gap must be zero-filled on extension, and nothing does it.

## Trigger scenario

Sequential, single-threaded, unprivileged — the exact CE shape (`ftruncate` → `pwrite64(off=8192,len=4096)` → `pread64(off=0,len=2)`; in the CE: cells of 2048B): seed a 3-page file with per-page patterns ('A','B','C'), `fsync`, `ftruncate(fd, 0)`, `pwrite` one page at offset 8192 (extends to 12288, hole = [0, 8192)), then `pread` the hole. On a fresh image the subject file is the first allocation, so the freed clusters are the lowest free range and first-fit reuse is deterministic.

## Developer intent

No TODO/FIXME/design note addresses zero-filling exFAT extension gaps. Upstream #3142 records that **ext2** got "hole-based storage … and zero-fill logic in the page cache" — i.e., developers treat hole-reads-as-zeros as the contract and fixed it for ext2; exFAT was not covered. The xfstests gap trackers (#3142/#3604) list no exFAT truncate→extend stale-data entry; the Specula harness notes "Physical cluster-reuse identity (TV3) … not covered". No masking safeguard exists on the read path.

## Reproduction result

Level **0** (pure black-box syscalls; no failpoints, timing, or injection). Ran `repro/test_bugMC-5_run.sh`, which boots the harness-built kernel (same revision + trace-only instrumentation as the confirmation worktree; `exfat/inode.rs` byte-identical) in QEMU with a fresh `mkfs.exfat -c 4096` image and a static guest test (`repro/test_bugMC-5_exfat_regrown_hole.c`). Captured output:

```
[ext2]  hole page 0: 0/4096 non-zero bytes ... MC5_RESULT CLEAN hole reads as zeros (correct)
[ramfs] hole page 0: 0/4096 non-zero bytes ... MC5_RESULT CLEAN hole reads as zeros (correct)
[exfat] tail page (written at 8192): all 'Z' (write landed)
[exfat] pread(off=0,len=2) returned bytes: 41 41 ('AA')
[exfat] hole page 0: 4096/4096 non-zero bytes, seed-'A' match: FULL; first16: 41 41 ... 41
[exfat] hole page 1: 4096/4096 non-zero bytes, seed-'B' match: FULL; first16: 42 42 ... 42
[exfat] MC5_RESULT BUG hole returned 8192 non-zero bytes (full seed-pattern pages: 2/2)
MC5_VERDICT REPRODUCED exFAT hole reads stale backing bytes; controls clean
```

The CE-exact `pread(off=0, len=2)` returned `41 41` ('AA') — byte-for-byte the MC trace's `out = <<seed, seed>>`. Full seed-pattern pages prove physical cluster reuse (nothing else ever wrote 'A'/'B'); the 'Z' tail proves EOF was published across the hole. ext2/ramfs controls match their clean MC runs.

Pre-verdict checklist: **(1)** Level 0 alone triggered it — **yes** (normal syscalls, no timing help). **(2)** N/A — no injection/patch. **(3)** Real consumer: the unprivileged userspace caller of `pread64` via `kernel/core/src/fs/file/inode_handle.rs:327` → `ExfatInode::read_at` receives bytes the contract says must be zeros; consequence crosses the syscall boundary (stale-data disclosure of the file's own truncated contents — and any future file reusing those clusters would disclose cross-file). **(4)** Permanent: every hole read serves stale bytes until overwritten; no downstream mechanism resolves it.

## Recommendation

Zero-fill the extension gap in `ExfatInode::write_at` (and any other extension path, e.g. `Inode::resize` growth): after growing, `page_cache.fill_zeros(old_size..offset)` (dirtying the gap pages so the zeros also reach disk on writeback), not just the old partial page tail. This both fixes the cached-read path and prevents stale disk bytes from surfacing after later cache eviction. A regression test mirroring this repro should run in the exFAT suite.

---

## Entry 6: Ramfs zero-count positional writes can enlarge the file

- **Finding ID**: MC-6
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/ 2>/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/work...
The cited code is `RamInode::write_at`. Now let me check the call chain and the counterexample trace.
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | head -3...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | grep -i s4
running wc -l /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt...
running sed -n 30,200p /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/outpu...
running grep -n "State [0-9]*:" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/s...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output && for s i...
The CE trace is clear: `pwrite64(fd, off=4, count=0)` on a 2-byte file → returns `Ok(0)` but L becomes 4. Now let me trace the real call chain from the syscall to `RamInode::write_at`, checking for any zero-length guard upstream.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/work...
No zero-length guard upstream. Let me check the other backends for comparison, and look at how existing repro tests in this run were built/executed.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/work...
ext2 explicitly guards `write_len == 0 → return Ok(0)` at line 57. Let me check exfat.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/work...
exfat shows the same pattern, but ext2 explicitly guards `write_len == 0`. Now let me look at the existing repro infrastructure in this run so I can reuse it.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && cat repro/test_bugM...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && head -60 repro/test...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && cat harness/identit...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && ls harness/src/ har...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output && diff harness/applie...
The prebuilt kernel's source is byte-identical to the worktree at the cited site. Now Phase 1 Step 2/3 — developer knowledge and known-status search. First the local git history, then the upstream tracker.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/work...
using web_search
using fetch_content: Show the write_at function of RamInode. Does it contain any guard for write_len == 0 or empty reader that returns early before expanding the file size? Quote the relevant lines.
Upstream `main` still has the unguarded code (unfixed). Now check whether it's been *reported* — issues and recently merged/closed PRs.
using fetch_content: List any issues or PRs (open or closed/merged) that report or fix this specific defect: a zero-length / zero-count write or pwrite at an offset beyond EOF enlarges a regular fil...
using get_search_content
using fetch_content
running for q in "zero-length+write" "ramfs+write+size" "empty+write+file+size" "pwrite+size" "zero+byte+write"; do echo "=== $q ==="; curl -s "https://api.github.co...
using ctx_execute
Two candidates to check: PR #3086 (positional I/O error handling, closed/merged) and PR #3778 (page-cache reads limit, open).
using ctx_execute
Neither matches MC-6's mechanism. Let me check the xfstests tracking issue #3142 for any mention of zero-length write semantics.
using ctx_execute
Novelty confirmed: no report of this mechanism. Let me check two remaining code details — `CurrentUserSpace::reader(ptr, 0)` behavior and `page_cache.resize` — then write the investigation record.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/work...
Bootstrap root is `RamFs::new_rootfs()` (mount_namespace.rs:102) — the initramfs root is ramfs. Investigation complete. Writing `investigation.md`:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-6/investigation.md
Phase 2 — Reproduction. First capture the Linux reference behavior on the host (tmpfs), then run the same test in the Asterinas guest.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-6_ramfs_empty_pwrite.c
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro && gcc -O2 -Wall...
Linux reference confirmed: size stays 2, EOF read returns 0. Now the guest init and run script.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-6_init.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-6_run.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro && timeout 650 b...
Bug triggered at Level 0. Before finalizing, one sanity check that the trace in the guest log confirms the same code path (not a different defect):
running grep -a "RamfsWriteAt\|tla" /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-outp...
The guest log has no tla_trace output for this boot (trace collection off), but the functional behavior matches the CE step-for-step: `pwrite64(off=4, len=0)` on a 2-byte file → `Ok(0)` with size 2→4, exactly the CE's `RamWriteMetadata` L:2→4 → `Return result=0 Ok`, violating `EmptyWriteNoEffect` through the cited lines (ramfs/fs.rs:751-758 publish `size = offset`; :765-766 resize the cache). Confirmed it's the right bug.

---

## MC-6 — Ramfs zero-count positional writes can enlarge the file

- **Source**: MC (real counterexample `spec/output/MC_hunt_s4_empty_ramfs_bfs1.out`, invariant `EmptyWriteNoEffect`)
- **Novelty**: NEW — searched asterinas/asterinas issues + PRs (any state) via GitHub API for `zero-length write`, `ramfs write size`, `empty write file size`, `pwrite size`, `zero byte write`, `pwrite64 zero`, `should_expand_size`, `zero-count write`, `empty positional write`, `write beyond EOF size`, `zero length pwrite`. Closest hits reviewed: #3086 (merged; zero-length preadv/pwritev *error validation* on pipes/O_PATH — different mechanism), #3778 (open; ramfs/exfat *read*-side buffer overrun past returned count — different mechanism), #3142 (xfstests gap tracker; no zero-write-size entry). Upstream `main` still carries the unguarded code (unfixed, unreported).
- **Location**: `kernel/core/src/fs/fs_impls/ramfs/fs.rs:751-758` (`write_len = reader.remain()`, `new_size = offset + write_len`, `inode_meta.size = new_size`), `:765-766` (`page_cache.resize`) — inside `RamInode::write_at` (fn at :733; finding cited :736/:742)

## Description

`RamInode::write_at` computes `new_size = offset + write_len` and publishes it whenever `new_size > file_size`, with no special case for `write_len == 0`. A zero-count positional write at an offset beyond EOF therefore sets `inode_meta.size = offset` and grows the page cache, then copies zero bytes and returns `Ok(0)`. POSIX write(2) requires an `nbyte == 0` write to a regular file to "return zero and have no other results"; Linux (verified on tmpfs and ext4) honors this. No layer upstream guards it: `sys_pwrite64` (syscall/pwrite64.rs:10) and `InodeHandle::write_at` (inode_handle.rs:343) both pass an empty reader straight through. The enlarged size is permanent — `sys_pwrite64` only fires `on_modify` when `write_len > 0`, and nothing reverts the size.

## Trigger scenario

Single-threaded, no race, no fault — direct from the CE (`pwrite64(4, 0)` on a file of `L=2`):
```c
fd = open("/ramfs/x", O_CREAT|O_RDWR|O_TRUNC);
pwrite(fd, "hi", 2, 0);        // size = 2
pwrite64(fd, buf, 0, 4);       // zero-count, beyond EOF -> returns 0, size becomes 4
fstat(fd);                     // st_size == 4 (Linux: 2)
pread(fd, b, 2, 2);            // returns 2 zero bytes (Linux: 0, EOF)
```

## Developer intent

The codebase itself encodes the intended contract: ext2's buffered *and* direct write paths explicitly no-op empty writes — `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:56-59`: `let write_len = reader.remain(); if write_len == 0 { return Ok(0); }` (again at :104). Ramfs (and exfat, out of scope here) lack the same guard — an inconsistency between backends, not a documented ramfs design choice. No TODO/test asserts the ramfs behavior either way.

## Reproduction result

**PASS — bug triggered at Level 0** (pure black-box guest syscalls; prebuilt instrumented kernel whose `ramfs/fs.rs` is `diff`-verified byte-identical to the confirmation worktree; ELF sha256 matches `harness/identity.json`).

Command: `bash repro/test_bugMC-6_run.sh` (docker `asterinas/dev:0.18.1-20260805`, QEMU/KVM, initramfs root = `RamFs::new_rootfs()`).

Guest output (copy-paste from `confirmation/MC-6/repro-guest.log`):
```
MC6_REPRO seed_size=2 (expect 2)
MC6_REPRO empty_pwrite_infile ret=0 errno=0 size=2 (expect ret=0 size=2)
MC6_REPRO empty_pwrite_beyond_eof ret=0 errno=0 size_after=4 (expect ret=0 size=2)
MC6_REPRO hole_read_at_eof ret=2 bytes=0000 (expect ret=0 at EOF)
MC6_REPRO empty_shared_write ret=0 errno=0 pos=4->4 size=4
MC6_RESULT BUG_TRIGGERED
MC6_SUMMARY empty pwrite64(off=4,len=0) on a 2-byte file returned 0 but enlarged size to 4 and made the hole readable
MC6_EXIT 0
```
Host Linux reference (same test binary, tmpfs `/dev/shm` and ext4 `/tmp`): `empty_pwrite_beyond_eof ret=0 size_after=2`, `hole_read_at_eof ret=0` → `MC6_RESULT OK`.

The `empty_pwrite_infile` control (offset 1 < EOF) correctly no-ops in the guest, isolating the anomaly to the beyond-EOF empty write. Lines demonstrating the bug: `size_after=4` vs expected 2, and `hole_read_at_eof ret=2` vs expected 0.

### Pre-REPRODUCED checklist
1. **Level 0 alone triggered it — yes.** Plain `open`/`pwrite`/`pwrite64`/`fstat`/`pread`, single-threaded, no timing help, no injection.
2. N/A — no Level 2/3 used; the pre-condition (2-byte file) is produced by an ordinary `pwrite`, exactly the CE's initial state.
3. **Real consumer**: any caller of `fstat` reads the corrupted `inode_meta.size` (set at ramfs/fs.rs:758); readers at `[oldEOF, offset)` get phantom zero-filled bytes via `RamInode::read_at` (ramfs/fs.rs:695-725), which computes readable length from the enlarged size — demonstrated in-guest. Not argued-only.
4. **Permanent**: size remains 4 after return (verified by post-call `fstat` and the subsequent hole read); no sync/guard/downstream mechanism reverts it. No mask.

## Recommendation

Mirror the ext2 guard at the top of `RamInode::write_at`'s file branch:
```rust
let write_len = reader.remain();
if write_len == 0 { return Ok(0); }
```
Also skip the `mtime`/`ctime` update for empty writes to fully match "no other results". The same guard belongs in the exfat backend (same unguarded pattern at exfat/inode.rs:740-772) — tracked separately from this ramfs-scoped finding.

---

## Entry 7: ExFAT zero-count positional writes can enlarge the file

- **Finding ID**: MC-7
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/debate.md

I'll start by reading the required skill file in full.
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
using ls
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
I have the full skill methodology. Now let me start Phase 1 (investigation). Let me create a task list and examine the affected code and counterexample.
using TaskCreate: Read exfat/inode.rs cited lines, trace call chain, check developer knowledge (git log, issues, PRs), determine novelty. Write investigation.md.
using TaskCreate: Write repro/test_bugMC-7_* exercising zero-count positional write beyond EOF on exFAT under Asterinas, run it, capture output, walk escalation ladder.
using TaskCreate: Decide verdict from decision table, write final response with header fields and sections, end with VERDICT line.
using TaskUpdate
using ls
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | grep -i...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s4_empty_exfat_bfs1.out
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
I have the exFAT `write_at` code. Let me pin down the exact cited lines and check for any zero-length guard.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
running cat > /tmp/linux_ref_zerowrite.c <<'EOF' #define _GNU_SOURCE #include <stdio.h> #include <fcntl.h> #include <unistd.h> #include <sys/stat.h> #include <string...
using web_search
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
using web_search
using fetch_content
using get_search_content
using fetch_content
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
Phase 1 code audit is solid. Now let me record `investigation.md`, then move to Phase 2 — first checking for existing build artifacts/recipes in the run.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls $R; echo ----; ls $R/.specula-outpu...
running W=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/workt...
The repro dir has per-finding artifacts (other findings — I won't read their contents). The shared `harness/` dir should hold the build/run recipe. Let me inspect that.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls -la $R/harness/ 2>/...
The harness has known-good build artifacts and scripts. Let me read them.
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/run.sh
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/build_guest.sh
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/run_guest.sh
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; cat $R/apply.s...
running docker -H unix:///var/run/docker.sock ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>&1 | head; echo ----; docker -H unix:///var/run/docker.sock images 2>...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/src/init.c
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; sed -n '1,60p' $R/.specula-output/harn...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; diff -rq $R/source $R/.specula-output/...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; ls -la $R/buil...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness; grep -c "SPECU...
running ls -la /dev/kvm 2>&1; which qemu-system-x86_64 2>&1; nproc
Known-good guest boot confirmed (`SPECULA_EXIT 0` in the last harness guest log), QEMU runs inside the container, KVM available. Let me write the Phase 1 `investigation.md` record now, then build the reproduction.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/investigation.md
using TaskUpdate
Now writing the Level 0 reproduction test (guest init + test in one static C binary) and its driver script.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-7_exfat_empty_pwrite.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-7_run.sh
Fixing a typo in the driver script before running (stray `MC7` cd):
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-7_run.sh
running chmod +x /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC...
The guest panicked. Let me examine the log to see where — and whether any test output appeared first.
running L=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/repro...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/work...
running sed -n '30,50p' /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/source/kernel/core/src/in...
The panic is in device init: my initramfs lacks the `/dev` directory (the harness initramfs includes `dev proc tmp ramfs ext2 exfat` dirs). Fixing the build step:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-7_run.sh
running timeout 10m /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bu...
running L=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/repro...
The per-probe lines start with "T1"/"T2" — my grep pattern missed them. Let me pull the full test output:
running L=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-7/repro...
Decisive result. All checklist items for REPRODUCED are satisfiable. Let me record the outcome and close out the tasks.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cp $R/confirmation/MC-...
using TaskUpdate
# Finding MC-7 — Confirmation Report

- **Source**: MC (real counterexample `spec/output/MC_hunt_s4_empty_exfat_bfs1.out`)
- **Novelty**: NEW — searched asterinas/asterinas issues **and** merged/closed PRs for this mechanism: closest hits are PR #639 (initial exFAT implementation), PR #3086 / commit de52fd1 (preadv/pwritev errno handling — it *added* the zero-length `write_at` probe that amplifies this bug, not a report of it), and mainline-Linux commit 6110151 (a different exFAT zero-byte defect — wrong errno — in a different codebase). Current upstream `main`'s `kernel/core/src/fs/fs_impls/exfat/inode.rs` still carries the identical unguarded `write_at` (verified by raw fetch), i.e. unfixed today. No report exists of THIS mechanism at THIS site.
- **Location**: `kernel/core/src/fs/fs_impls/exfat/inode.rs:712` (missing `write_len == 0` guard; extension preparation at :725, size publish at :743 — pristine line numbers, equal to upstream `main`)

## Description
`ExfatInode::write_at` has no early return for zero-length writes. For `pwrite64(fd, buf, 0, off)` with `off > size`, `new_size = offset + 0 = offset > file_size`, so the extension path runs anyway: `inner.resize(new_size)` allocates exFAT clusters, `page_cache.resize` enlarges the cache bound, the zero-byte copy is a no-op, and `inner.size = new_size` publishes the caller's offset as the file's logical size. The syscall returns 0 while the file has grown — directly violating Linux's contract ("If count is zero … 0 is returned without causing any other effects", confirmed on host ext4+tmpfs: `pwrite ret=0 size_after=2`).

## Trigger scenario
```
fd = open("/exfat/f", O_RDWR|O_CREAT|O_TRUNC); write(fd, "AB", 2);
pwrite64(fd, buf, 0, 4096);            /* MC scenario: size 2 -> 4096 */
```
Two further real syscall surfaces hit the same path: `pwritev(fd, iov, 0/empty, 8192)` — `do_sys_pwritev` (`kernel/core/src/syscall/pwritev.rs:86-92`) deliberately probes with a zero-length `write_at(offset)`, so a *defensive errno probe* extends an exFAT file; and `lseek(fd, off, SEEK_SET) + write(fd, buf, 0)` (shared-offset path). No zero-count guard exists at `sys_pwrite64` or `InodeHandle::write_at` either.

## Developer intent
ext2 in the same tree guards explicitly at `ext2/inode/file.rs:45-47`: `if write_len == 0 { return Ok(0); }` (pristine upstream code) — evidence the project intends zero-count writes to be no-ops; exFAT simply misses the guard. No TODO/FIXME near the exFAT site; no filed upstream report of the extension behavior.

## Reproduction result
**Level 0 (pure black-box, unprivileged uid 1000, no failpoints, deterministic).** Command: `repro/test_bugMC-7_run.sh` — guest test `repro/test_bugMC-7_exfat_empty_pwrite.c` run as `/init` under the known-good harness kernel (provenance: `harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf`, built 2026-09-08 18:19 from a source tree verified byte-identical to this finding's worktree, `diff -rq` clean; harness guest log shows prior `SPECULA_EXIT 0` boot). Actual output (copy-paste from `confirmation/MC-7/repro-guest.log`):

```
MC7: uid=1000 starting zero-count write probes
T1 exfat pwrite64(fd,b,0,4096): ret=0 errno=0 size 2->4096 blocks 8->8 seed_ok=1 hole_read=16 hole_zeros=1 => FILE ENLARGED
T2 ext2  pwrite64(fd,b,0,4096): ret=0 errno=0 size 2->2 blocks 8->8 seed_ok=1 hole_read=0 hole_zeros=1 => no effect
T3 exfat pwritev empty-iov @8192: ret=0 errno=0 size 2->8192 blocks 8->16 seed_ok=1 hole_read=16 hole_zeros=1 => FILE ENLARGED
T4 exfat lseek+write(0) @16384: ret=0 errno=0 size 2->16384 blocks 8->32 seed_ok=1 hole_read=16 hole_zeros=1 => FILE ENLARGED
T5 exfat pwrite64(fd,b,0,@EOF): ret=0 errno=0 size 2->2 blocks 8->8 seed_ok=1 hole_read=0 hole_zeros=1 => no effect
T6 exfat pwrite64(fd,b,0,1)  : ret=0 errno=0 size 2->2 blocks 8->8 seed_ok=1 hole_read=0 hole_zeros=1 => no effect
MC7_SUMMARY t1_exfat=BUG t2_ext2=clean t3_pwritev=BUG t4_lseek_write=BUG t5_at_eof=clean t6_inside=clean
MC7_RESULT REPRODUCED
SPECULA_EXIT 0
```

Match with the CE: same action (`pwrite64`, O beyond EOF, N=0), same invariant (`EmptyWriteNoEffect`: L 2→4 in CE, 2→4096 in guest), same root cause path (ExfatAllocate/ResizeCapacity/ExfatWritePublish — guest shows `st_blocks` 8→16→32, i.e. real cluster allocation when `off` crosses the 4 KiB cluster boundary, and the hole reads back as zeros). T5/T6 confirm the defect is precisely the `new_size > file_size` path with `write_len == 0`. Levels 1–3 not needed; Level 0 alone triggers it on every run.

**Pre-REPRODUCED checklist:**
1. **Level 0 alone triggered it — yes.** Ordinary `pwrite64`/`pwritev`/`lseek`+`write` syscalls from an unprivileged process; no timing help, no failpoints.
2. n/a — no state injection or source patch used (kernel unmodified, byte-identical to the run's instrumented source; instrumentation is trace-stamping only, logic untouched).
3. Real consumers demonstrated in-guest: `fstat` (st_size 2→4096) and subsequent `pread` (bytes 2..17 now readable as zeros — a hole the caller never created; read path clamps on the published `inner.size` at `exfat/inode.rs:655-661`); storage accounting (`st_blocks` 8→16/32). Accidental trigger via the `pwritev` errno probe (T3).
4. The bad state is **permanent**: size stays enlarged after return (observed via post-call `fstat`), and `write_inode` persists it to the on-disk dentry on sync. No downstream mechanism shrinks it back.

## Recommendation
Add the ext2-style guard at the top of `ExfatInode::write_at` (and mirror it in `write_direct_at` for symmetry, though O_DIRECT's block-alignment check already rejects `len == 0`):
```rust
let write_len = reader.remain();
if write_len == 0 { return Ok(0); }
```
This matches Linux semantics, matches ext2, and neutralizes the `pwritev` empty-iov probe side effect. The same unguarded pattern exists in ramfs (`ramfs/fs.rs` write_at expands `inode_meta.size` when `offset > size`) — noted for the record but out of this finding's scope.

---

## Entry 8: Ramfs zero-progress failed writes can publish the full requested extent

- **Finding ID**: MC-8
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
running ls /home/chin39/Documents/play/Specula/skills/bug-confirmation/
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
using ls
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/ | grep -i...
running SPEC=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec; ls $SPEC/outpu...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s4_fault_ramfs_bfs1.out
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/work...
No QEMU/osdk on this host. Let me trace the full call chain first, then assess reproduction options.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/work...
ext2 publishes size **after** a successful copy and rolls back on error — ramfs does the opposite. Strong contract evidence. Let me check exfat and existing tests, then do the developer-knowledge search.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/worktree/test/initramfs/src...
This is the ext2 counterpart test — developers explicitly test failed-write aftermath there. Now let me check how ramfs is exposed to userspace (where it's mounted), then search upstream.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/work...
using web_search
No direct hit yet. Let me query the GitHub search API directly for this specific mechanism.
running curl -s "https://api.github.com/search/issues?q=repo:asterinas/asterinas+ramfs+write+size&per_page=20" | python3 -c " import json,sys d=json.load(sys.stdin)...
running curl -s -o /tmp/gh1.json "https://api.github.com/search/issues?q=repo:asterinas/asterinas+ramfs+write+size&per_page=20" && python3 -c " import json d=json.lo...
running for q in "EFAULT+write" "write+bad+buffer" "failed+write+extends" "write_at+rollback"; do curl -s -o /tmp/gh2.json "https://api.github.com/search/issues?q=re...
Issue #711 looks highly relevant. Let me read it.
running curl -s -o /tmp/gh711.json "https://api.github.com/repos/asterinas/asterinas/issues/711" && python3 -c " import json d=json.load(open('/tmp/gh711.json')) pri...
running curl -s -o /tmp/gh3.json "https://api.github.com/search/issues?q=repo:asterinas/asterinas+ramfs+in:title&per_page=30" && python3 -c " import json d=json.load...
running curl -s -o /tmp/upstream_ramfs.rs "https://raw.githubusercontent.com/asterinas/asterinas/main/kernel/core/src/fs/fs_impls/ramfs/fs.rs" && grep -n "should_exp...
Upstream `main` still publishes `inode_meta.size = new_size` before `page_cache.write(offset, reader)?` — the mechanism is **unfixed**. Now Phase 2: check for existing build artifacts/recipes before attempting a build.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls $OUT/harness/ 2>/...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; head -60 $OUT/harnes...
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls $OUT/harness/buil...
The harness already has a built kernel and uses rootful Docker + KVM. Let me inspect the runner.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; head -100 $OUT/harne...
Docker is available and a prebuilt instrumented kernel exists. Let me verify the kernel image's provenance vs my worktree.
running RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; ls $RUN; ls -la $RUN/source 2>/dev/n...
running RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; cd $RUN/source && git log --oneline...
running RUN=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency; head -40 $RUN/.specula-output/repro/...
The prebuilt kernel matches my worktree's ramfs code. Now let me look at the harness init to copy the guest-exit convention.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -n "0xf4\|ioper...
The harness convention is clear (`SPECULA_EXIT <n>` + `RB_POWER_OFF`). Let me confirm the initramfs root is ramfs-backed, then write the repro.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/work...
Initramfs unpacks into a **ramfs root**, so `/` directly exercises `RamInode::write_at`. Phase 1 evidence is complete. Writing `investigation.md`, then the repro.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/investigation.md
Now the Phase 2 reproduction test:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-8_ramfs_efault_extent.c
running ls -la /dev/kvm 2>&1; docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i asterinas; docker -H unix:///var/run/docker.sock images 2>/dev/...
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-8_run.sh
running chmod +x /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC...
The kernel panicked during early init path resolution. Let me inspect the full log and that source line.
running OUT=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; head -40 $OUT/repro/...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/source && grep -rn "init_in_first_proc...
The kernel requires `/dev` in the initramfs. Fixing the build to include the standard directories:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugMC-8_run.sh
running timeout 280 bash /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/te...
**REPRODUCED at Level 0** — deterministic, first attempt. Let me pin the pristine line numbers for the report header.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-8/work...
All verified. Final report:

---

# MC-8 — Ramfs zero-progress failed writes publish the full requested extent

- **Source**: MC (counterexample `spec/output/MC_hunt_s4_fault_ramfs_bfs1.out`, invariant `AcceptedExtent`, 14-state trace)
- **Novelty**: NEW — searched the asterinas/asterinas tracker (open+closed issues, merged+closed PRs): #711 is about partial-progress EFAULT *return-value* semantics (different mechanism/site), #3297 is an ext2-only rollback PR (confirms intent, not this site), #3778 is a read-side clamp. Nothing reports ramfs's publish-before-copy ordering, and upstream `main` still has `inode_meta.size = new_size` before `page_cache.write(offset, reader)?` in `kernel/core/src/fs/fs_impls/ramfs/fs.rs` — unfixed.
- **Location**: `kernel/core/src/fs/fs_impls/ramfs/fs.rs:742` (publish) vs `:750` (fallible copy)

## Description

`RamInode::write_at` assigns `inode_meta.size = new_size` (and `blocks`) and resizes the page cache **before** attempting the fallible copy from the user `VmReader`. If the source is inaccessible from the first byte, the copy fails with `PageFault`→`EFAULT` having copied 0 bytes, the error propagates unchanged through `InodeHandle::write_at` (`inode_handle.rs:343`) and `sys_pwrite64`, and nothing restores the old size. The failed, zero-progress write permanently leaves the file larger, with the new range zero-filled. ext2 (`file.rs:282` — copy first, `set_file_size` only on success, `rollback_write` on error) and exfat (`inode.rs:729` — `inner.size = new_size` only after the copy succeeds) both implement the opposite order, matching Linux v6.12's `generic_perform_write` (i_size advances in `write_end` only for copied bytes; a first-byte fault never calls `write_end`).

## Trigger scenario

Real API only, reproducible by any unprivileged process on ramfs/`/dev/shm`/tmpfs (the initramfs root itself is `RamFs::new_rootfs()`):

1. `fd = open("/f", O_RDWR|O_CREAT|O_TRUNC)`; `write(fd, "hi", 2)` → size 2.
2. `bad = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)`.
3. `pwrite(fd, bad, 2, 2)` → `-1/EFAULT`, 0 bytes copied (`VmSpace::reader` at `ostd/src/mm/vm_space.rs:160` only bounds-checks the range; the first-byte fault surfaces from the copy loop in `ostd/src/mm/io/mod.rs`'s `read_fallible`).
4. `fstat(fd)` → `st_size == 4`; `pread(fd, buf, 4, 0)` returns `"hi\0\0"`.

## Developer intent

ext2's explicit `rollback_write` and both other backends' publish-after-copy show the intended contract: a failed extending write must not grow the file. The in-tree regression test `test/initramfs/src/regression/fs/ext2/short_rw.c` asserts a failed write leaves no trace. No comment/TODO in ramfs suggests the publish-first order is deliberate; upstream has never reported or fixed this exact mechanism.

## Reproduction result

**PASS — Level 0 (pure black-box), deterministic.** Test: `repro/test_bugMC-8_ramfs_efault_extent.c` run as `/init` via `repro/test_bugMC-8_run.sh` (prebuilt instrumented kernel `harness/build/kernel-direct/...qemu_elf`, same revision 60494858 + trace instrumentation, `ramfs/fs.rs` byte-identical to this worktree; QEMU/KVM in `asterinas/dev:0.18.1-20260901`). Output (`repro/test_bugMC-8_guest.log`):

```
[ramfs] size after seed write = 2 (expect 2)
[ramfs] pwrite(PROT_NONE buf, 2, off=2) = -1 errno=14 (Bad address)
[ramfs] size after failed write = 4 | pread(4, off=0) = 4 bytes = 68 69 00 00 ("hi..")
[ramfs] control pwrite(good buf, 2, off=2) = 2 errno=0, size now 4 (expect 2 written, size 4)
[ext2] pwrite(PROT_NONE buf, 2, off=2) = -1 errno=14 (Bad address)
[ext2] size after failed write = 2 | pread(4, off=0) = 2 bytes = 68 69 41 41 ("hiAA")
MC8_RESULT: BUG PRESENT — failed zero-progress write left the ramfs file extended with zero-filled bytes
MC8_CONTROL_EXT2: SIZE UNCHANGED (same sequence on ext2 left size unchanged, matching Linux semantics)
SPECULA_EXIT 0
```

Matches the CE exactly: `pwrite64(O=2,N=2)` at EOF → `EFAULT`, `accepted={}`, yet L: 2→4 and the new pages read as zeros. The identical sequence on ext2 (same guest, same run) leaves size 2 and hits EOF at offset 2 — confirming the ramfs-specific defect the model isolated (only `MC_hunt_s4_fault_ramfs` produced a counterexample).

**Pre-REPRODUCED checklist:**
1. **Level 0 alone triggered it — yes.** Public syscalls only; `PROT_NONE` mapping is ordinary userspace state; no timing/failpoint/injection.
2. n/a — no Level 2/3 escalation needed.
3. **Real consumer**: any subsequent reader/stat caller — demonstrated in-guest: `pread` delivers 4 bytes including two phantom zeros (`RamInode::read_at` bounds reads by the published `self.size()`, `ramfs/fs.rs:704`), `fstat` reports the grown size.
4. **Permanent**: no rollback path exists for ramfs; the enlarged size and zero-filled cache persist across later syscalls. No mask.

## Recommendation

Mirror the ext2/exfat structure in `RamInode::write_at`: attempt `page_cache.write(offset, reader)` first, and only on success assign `inode_meta.size`/`blocks`; on error, roll back the cache resize (`page_cache.resize(old_aligned, new_size)`) and leave metadata untouched. A follow-up should also decide partial-progress semantics (bytes copied before the fault currently also return `Err` with the extension kept) — that overlaps upstream issue #711 but is outside this finding's zero-progress witness.

---

## Entry 9: VmIo no-short-transfer contract conflicts with VMO capacity-clamped success

- **Finding ID**: CR-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/references/repair-request-format.md
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/ostd/src/mm/io/mod.rs
Now the VMO implementation at the cited lines:
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/vm...
The worktree is instrumented with `tla_trace` calls. Now let me trace the call chain — who implements `VmIo` and who calls `Vmo::read`:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/vm...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
Key facts so far: ramfs pre-computes `read_len` from metadata file size and returns it regardless of what `Vmo::read` actually delivered (that's the MC-1 mechanism, explicitly out of CR-1's scope). CR-1 is about the **trait contract conflict itself**. Now let me check ext2/exfat read paths and any `read_val`/`read_slice` callers that rely on full delivery:
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
exfat's buffered `read_at` (inode.rs:645-668) also clamps `read_off`/`read_len` to file size but passes the **unclamped writer** to `page_cache.read` — the VMO can then deliver up to `capacity` bytes while exfat returns only `read_len`. Let me check exfat's write/resize paths to see what lives in `[size..capacity)`:
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
exfat's `resize` allocates clusters without zeroing them. Let me check where the logical `size` is set on extension, and look at the `Vmo` options for how capacity relates to size:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
Let me check the worktree's git identity and the available harness infrastructure for running reproductions:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness/ 2>/dev/null;...
There's existing harness infrastructure (build_guest.sh, run_guest.sh) and prior repro tests. I'll read the harness docs (shared infra, not finding content) to reuse the proven recipe:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && head -60 IN...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && sed -n 1,80...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/harness && cat src/ini...
Let me check the exfat dentry read context and the exfat backend's read path (any tail zeroing):
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
reading /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/worktree/kernel/core/src/fs...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
Now let me check `InodeExt::read_bytes_at` and the VFS-level callers, plus the `HasVmReaderWriter` blanket impl's read semantics (another VmIo impl family for comparison):
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
using web_search
PR #3256 is a *different* mechanism (uninitialized-memory leak via write path). Let me verify upstream `main` still has the capacity-clamped read (a recent fix would make this KNOWN):
using fetch_content: Show the exact code of the Vmo::read function (the pub(crate) fn read that takes offset and writer). Does it clamp read_len to self.size() and return Ok(()) on short/zero delive...
Upstream `main` still has the identical clamp — no fix landed. One more targeted tracker search for this exact mechanism, then I'll record the investigation:
using fetch_content: List any issues or PRs whose title or description mentions: short reads, VmIo contract, reading beyond EOF/file size into user buffer, capacity-clamped read, or read overwriting...
using fetch_content
Tracker searches (issues + PRs, open and closed) show no report of this mechanism; upstream `main` still has the identical clamp. Now let me verify the prebuilt kernel artifact's provenance before reusing it:
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && ls -la; echo ===; ls .specula-outpu...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && ls source/ | head; diff -q source/k...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/source && find . -name "*.rs" -newer ....
No `.rs` file is newer than the prebuilt kernel ELF — provenance is clean (kernel matches current `source/`, which is byte-identical to my CR-1 worktree at all four cited sites). Now let me verify the syscall read path carries the user `VmWriter` directly (no bounce buffer that would hide over-delivery):
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/work...
Syscall path confirmed: `sys_read`/`sys_pread64` pass a `VmWriter` over the **user buffer directly** down to `Vmo::read` — no bounce buffer, so capacity-clamped over-delivery physically lands in userspace. Phase 1 evidence is complete. Let me write `investigation.md`:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/investigation.md
Phase 1 done. Now Phase 2 — check environment, then write the reproduction:
running docker -H unix:///var/run/docker.sock info --format '{{.ServerVersion}}' 2>&1 | head -2; ls -la /dev/kvm 2>&1; docker -H unix:///var/run/docker.sock images -...
Docker + KVM ready, image present. Writing the guest test and runner:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-1_vmo_overdelivery.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-1_run.sh
Executing the Level 0 reproduction (pure black-box syscalls on the real kernel):
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && chmod +x .specula-output/repro/test...
**REPRODUCED at Level 0.** The anomaly fired on the very first attempt with plain syscalls. Let me record the verdict body in the work dir:
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/verdict-body.md
## CR-1 — confirmation result

**Pre-verdict checklist (required for REPRODUCED):**

1. **Level 0 alone triggered it — yes.** Pure black-box: `open`/`pwrite`/`read`/`pread64` as unprivileged uid 1000, sequential, no concurrency, no timing help, no state injection, no source patch.
2. Level 2/3 — not used.
3. **Real consumer observing the wrong outcome:** the userspace reader itself. `sys_read` (`kernel/core/src/syscall/read.rs:24-32`) and `sys_pread64` (`pread64.rs:33-38`) build the `VmWriter` directly over the user buffer; bytes land there during the syscall. A program that `pread`s a 100-byte ramfs/exfat file into an 8192-byte buffer gets `ret=100` **and bytes [100..4096) overwritten**; an EOF read returns 0 and still overwrites 3996 bytes. Nothing restores the clobbered bytes afterward — the state is permanent from the caller's view.
4. **Not transient/masked:** the write into the user buffer is the final effect of the syscall; no downstream mechanism repairs it. ext2's `writer.limit(read_len)` is a per-caller discipline, not a system-wide mask — and it is absent in ramfs/exfat, where the harm fires today.

---

- **Source**: Code Review
- **Novelty**: NEW (searched asterinas/asterinas issues **and** open/closed/merged PRs for this mechanism on 2026-09-08; nearest hits are different mechanisms: merged PR #3256 = uninitialized-memory leak via the *write* path, issue #711 = EFAULT mid-copy, PRs #3729/#3582 = unrelated short-read features. Upstream `main` still carries the identical capacity clamp — no fix landed.)
- **Location**: `ostd/src/mm/io/mod.rs:75` (contract) · `kernel/core/src/vm/page_cache/vmo/mod.rs:533` (clamped `Vmo::read`) · `kernel/core/src/vm/page_cache/mod.rs:354` (`impl VmIo for PageCache`) · affected callers `kernel/core/src/fs/fs_impls/ramfs/fs.rs` (`read_at`) and `kernel/core/src/fs/fs_impls/exfat/inode.rs:667` · unaffected control `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:275`

## Description

`VmIo::read` documents "No short reads" (complete transfer or error). `Vmo::read` clamps to the page-aligned capacity and returns `Ok(())` after `min(avail, capacity - offset)` bytes — including zero. The trait side is authoritative: the `HasVmReaderWriter` blanket impl and `IoMem` both enforce all-or-error. ext2 compensates with `writer.limit()`; **ramfs and exfat pass the unclamped user writer and return a size-clamped count, so the returned count fails to account for up to `align_up(size) - ret` bytes observably delivered into the user buffer** — the steady-state, race-free over-delivery side of the conflict (complementing MC-1's racy over-report). `read_bytes`/`read_val` callers are unreachable-beyond-size today (latent only); the zero-capacity branch is benign-today (all callers pre-clamp to 0).

## Trigger scenario

Sequential, uid 1000: create file, `pwrite` 100 bytes (size 100, capacity 4096), prefill an 8192-byte buffer with `0x5A`, `pread(fd, buf, 8192, 0)`. Linux oracle: return 100, tail untouched. Also `pread` at offset 4096 (EOF): expect 0 and zero bytes written.

## Developer intent

Trait docs (stable since ≥0.4.2), both other impl families, and `VmIoFill`'s self-flagged exception establish no-short-read as the norm; `PageCache`/`Vmo` docs make the page-aligned capacity deliberate layering but expose it through a contract-violating `impl VmIo` with no callout. ext2's `writer.limit` is the intended caller discipline; ramfs/exfat lack it.

## Reproduction result

**PASS — Level 0.** `timeout 500 bash .specula-output/repro/test_bugCR-1_run.sh` (guest rc=33, clean poweroff). Artifacts: `.specula-output/repro/test_bugCR-1_vmo_overdelivery.c`, `.specula-output/repro/test_bugCR-1_run.sh`, log `.specula-output/repro/test_bugCR-1_guest.log`; investigation at `confirmation/CR-1/investigation.md`. Kernel: provenance-verified prebuilt harness ELF (source byte-identical to this worktree at all cited files). Verbatim decisive output:

```
CR1|ramfs/small/pread@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[100..4095]
CR1|ramfs/small/pread@0|ANOMALY over-delivery: kernel wrote 3996 bytes beyond returned count 100
CR1|ramfs/small/pread@eof4096|ret=0 clobbered_beyond_ret=3996 (zeros=3996 donorC3=0 other=0) span=[0..3995]
CR1|ramfs/small/read@0|ret=100 clobbered_beyond_ret=3996 ... ANOMALY over-delivery
CR1|ext2/small/pread@0|ret=100 clobbered_beyond_ret=0 ... clean
CR1|ext2/small/pread@eof4096|ret=0 clobbered_beyond_ret=0 ... clean
CR1|exfat/small/pread@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996) span=[100..4095] ANOMALY
CR1|exfat/small/pread@eof4096|ret=0 clobbered_beyond_ret=3996 (zeros=3996) span=[0..3995] ANOMALY
CR1|ramfs/empty/pread@0|ret=0 clobbered_beyond_ret=0 ... clean
CR1|exfat/victim/pread@0|ret=100 clobbered_beyond_ret=3996 (zeros=3996) span=[100..4095] ANOMALY
CR1|end|anomalies=7
CR1_DONE child_status=10752
```

ramfs and exfat over-deliver on both `read` and `pread64`, including after an EOF read returning 0; ext2 is clean throughout. The exfat tail is zeros here (first commit of a new file's page is short-circuited to `BioStatus::Zeros` while `inner.size == 0`, and full-page writeback then zeroes the on-disk tail), so no stale-data leak was observed — the over-delivery defect itself is fully demonstrated.

## Recommendation

Fix at the `PageCache` boundary: make `PageCache as VmIo` honor the contract (error when `offset + avail` exceeds capacity, like the other impls) and give filesystems an explicit clamped/return-count read interface; at minimum, have ramfs and exfat adopt ext2's `writer.limit(read_len)` discipline so a returned count always accounts for every delivered byte.

---

## Entry 10: Resize documentation contradicts fallible tail clearing and exFAT branch order

- **Finding ID**: CR-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/debate.md

reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/SKILL.md
running ls /home/chin39/Documents/play/Specula/skills/bug-confirmation/ /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/ 2>/dev/null
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/guide.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/01-investigation.md
reading /home/chin39/Documents/play/Specula/skills/bug-confirmation/phases/02-reproduction.md
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
Now let me examine the cited code sites.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
Let me check whether these doc comments exist in upstream Asterinas or were added by the Specula harness, and check the fallibility of the extension tail-clearing path more closely.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
Let me compare these files against upstream Asterinas at the pinned SHA to determine provenance of the doc comments.
running cd /tmp && rm -rf ast-upstream && mkdir ast-upstream && cd ast-upstream && for f in "kernel/core/src/vm/page_cache/mod.rs" "kernel/core/src/fs/fs_impls/exfat...
running cd /tmp/ast-upstream && grep -n "cannot return an error\|Size Synchronization\|fill_zeros" mod.rs | head; echo ====; grep -n "Important: To enlarge" inode.rs...
running cd /tmp/ast-upstream && sed -n '196,262p' mod.rs; echo =====; sed -n '1436,1468p' inode.rs; echo =====; sed -n '135,142p' inode.rs
The upstream provenance is confirmed. Now let me examine `write_pages_with_backend`/`collect_pages` to see exactly when extension tail-clearing can call into the backend or fail.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
Let me look at the full exFAT `write_at` to see where the logical size gets published on extension, and check the ostd RwLock semantics.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
Let me check the ostd RwLock semantics (read while holding the write guard) and the exFAT backend read path.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
The ostd RwLock is spin-based and non-reentrant. Let me trace exactly when the extension tail-clear reaches the backend via `commit_on_internal`.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
Critical check — upstream exFAT `write_at` and `submit_read_bio`, to see whether the write-guard-held backend read chain exists upstream too.
running cd /tmp/ast-upstream && grep -n "fn write_at\|fn submit_read_bio\|inner.write()\|page_cache.resize\|inner.resize\|self.inner.read()" inode.rs | sed -n '1,40p'
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
The exFAT `inner` is an `RwMutex` (sleeping, non-reentrant). Let me verify the RwMutex read-under-held-write behavior and check the page-cache initial size for a loaded inode.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/work...
VMO size is page-aligned at creation (4096 for a 512-byte file), so `fill_zeros(512..1024)` proceeds to the backend read path. The deadlock chain is code-confirmed. Now Phase 1 Step 2/3: search upstream tracker for prior reports, and check the environment for build artifacts.
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/ 2>/dev/null; ls /home...
running which cargo osdk cargo-osdk qemu-system-x86_64 2>/dev/null; ls ~/.cargo/bin 2>/dev/null | head; cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && w...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && s...
A prior attempt of this same turn left investigation and a guest log showing the deadlock reproduced. Let me inspect what infrastructure exists so I can re-run the reproduction properly and place the test file in `repro/` as required.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && f...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && c...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && g...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && w...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && s...
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2 && l...
running ls /tmp/asterinas-01b-604948581 2>/dev/null | head; find /tmp/asterinas-01b-604948581 -maxdepth 3 -name "*.c" -o -maxdepth 3 -name "*.sh" 2>/dev/null | head -20
running ls -la /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/ 2>/dev/n...
running for d in CR-1 MC-1 MC-2 MC-3 MC-4 MC-5 MC-6 MC-7 MC-8; do p=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-siz...
running ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-2/ 2>/...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; ls -la $R/harness/buil...
The infrastructure is clear. Let me check my current environment's tooling (the previous run used a dev container with `/work`).
running whoami; ls /work 2>/dev/null | head -3; for t in qemu-system-x86_64 gcc cpio mkfs.exfat mkfs.ext2; do command -v $t || echo "MISSING $t"; done; ls /dev/kvm 2...
running command -v docker podman nix nix-shell 2>/dev/null; ls /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-rea...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cat $R/harness/run_gue...
running docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | head; docker images 2>/dev/null | grep -i asterinas | head
Now let me look at how the harness's own guest init performs mounts, to reuse exact APIs.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; cat $R/harness/build_g...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -n "mount\|vda\|v...
Now I have everything needed. Let me write the reproduction test and driver script.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-2_exfat_resize_tailclear.c
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-2_run.sh
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && timeout 560 bash .specula-output/re...
The image needed pulling and the timeout hit mid-pull. Let me wait for the pull to finish, then re-run.
running timeout 500 docker pull asterinas/dev:0.18.1-20260805 2>&1 | tail -3; docker image inspect asterinas/dev:0.18.1-20260805 --format 'image ready: {{.Id}}' 2>/d...
Image is present locally now. Re-running the reproduction.
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && timeout 550 bash .specula-output/re...
Claim A reproduced (deadlock). The T2 trace events are missing — let me check whether tracing needs arming.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -c SPECULA_RAW $R...
Tracing is armed per-thread via `prctl`. Let me see how the harness's guest code arms/drains it.
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; grep -n "0x53504543\|0...
running R=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output; sed -n '1,140p' $R/har...
The guest must arm/drain tracing via prctl. Let me update the T2 probe in the test.
editing /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-2_exfat_resize_tailclear.c
running cd /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency && timeout 550 bash .specula-output/re...
Both claims are now runtime-confirmed. Before recording `NEW`, let me run a fresh prior-report search on the asterinas tracker myself.
running for q in "exfat+page_cache+resize+deadlock" "fill_zeros+cannot+return+an+error" "exfat+write+deadlock+inode+lock"; do echo "== $q"; curl -s --max-time 25 "ht...
running for q in "exfat+page_cache+resize+deadlock" "exfat+write+deadlock+inode+lock" "page+cache+resize+fill_zeros"; do curl -s --max-time 25 "https://api.github.co...
using ctx_execute
No prior report exists for this mechanism — **NEW** confirmed. Let me record the Phase 2 outcome in the investigation file and clean up the container.
running docker rm -f specula-cr2-repro >/dev/null 2>&1; rm -f /tmp/gh-*.json; echo cleaned
running cat >> /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-2/...
# CR-2 — Confirmation Result

- **Source**: Code Review (code-review-only finding, brief §6.3; MC hunts returned no violation for this mechanism)
- **Novelty**: NEW (GitHub issues+PRs incl. closed/merged searched twice — this turn: "exfat page_cache resize deadlock", "exfat write deadlock inode lock", "page cache resize fill_zeros" → only #958/#2937/#2953/#3048/#3084/#3421/#3505, all different mechanisms; exact-phrase searches on both doc strings → source files only; upstream `main` checked 2026-09-08 — no fix landed)
- **Location**: `kernel/core/src/vm/page_cache/mod.rs:202-204` (doc) vs `:255` (fallible extension tail-clear); live defect at `kernel/core/src/fs/fs_impls/exfat/inode.rs:751` (`page_cache.resize` under `self.inner.write()`) → `:149` (`submit_read_bio` takes `self.inner.read()`); comment-vs-code at `kernel/core/src/fs/fs_impls/exfat/inode.rs:138-139` vs `:1491-1494`

## Description

The finding's two documentation-vs-code claims are both factually correct, and reconciling claim A with the real backend path exposed a live, unprivileged-userspace-triggerable kernel deadlock — not merely a prose mismatch:

1. **Claim A**: `PageCache::resize` doc says *"Extending the page cache does not eagerly allocate pages and therefore cannot return an error."* The extension branch actually runs `fill_zeros(old_size..tail_end)?` — fallible (frame allocation, backend I/O), and for a backed cache with an uncached tail page it synchronously calls `backend.read_page`. exFAT's `write_at` does this while holding the inode write guard (`self.inner.write()`, inode.rs:735), and exFAT's backend **is the inode itself**: `submit_read_bio` starts with `self.inner.read()` (inode.rs:151) on a non-reentrant sleeping `RwMutex` → same-task self-deadlock.
2. **Claim B**: the exFAT comment says shrink updates page-cache size *after* inode size; the code shrinks the page cache *before* `inner.resize`. Runtime trace confirms the code order.

## Trigger scenario

Public syscalls only: create a 100-byte file on exFAT (100 % 4096 ≠ 0), fsync, umount, remount (fresh `ExfatFs` → empty page cache), then `pwrite64(fd, buf, 16, 100)`. Extension resize → `fill_zeros(100..116)` → tail page absent → `commit_on_internal(CommitMode::Read)` → `backend.read_page` → `submit_read_bio` → `self.inner.read()` while the same task holds the write guard → syscall never returns, with the inode write guard and fs lock held forever.

## Developer intent

Upstream knows the hazard class but missed this instance: the FIXME in `write_direct_at` (inode.rs:817-821) says it is "not possible to acquire the inner write lock in advance, because the page cache flush operation needs to acquire the backend lock, and the backend here is the inode itself" — worked around for flush in the direct-I/O path, but the identical hazard via `resize`→`fill_zeros`→backend read in buffered `write_at` is unmitigated. No caller relies on the doc's false infallibility promise (all `page_cache.resize` sites propagate with `?`). No test asserts extension infallibility.

## Reproduction result

**PASS — Level 0** (pure black-box; watchdog only *detects* the hang, no timing/fault injection). Command: `bash .specula-output/repro/test_bugCR-2_run.sh` (guest test `repro/test_bugCR-2_exfat_resize_tailclear.c` as `/init`; prebuilt instrumented kernel under QEMU/KVM). Verbatim output (log: `confirmation/CR-2/repro-guest.log`):

```
T0 exfat cached-tail extend: ret=16 errno=0 (expect ret=16 errno=0)
T1b ext2 remounted uncached-tail extend: ret=16 errno=0 (expect ret=16 errno=0)
T1 exfat after remount: size=100 (expect 100)
T1 exfat uncached-tail extend: pwrite64 DID NOT RETURN within 10s -> kernel thread stuck
CR2-CLAIM-A: REPRODUCED -- extending pwrite64 on exfat self-deadlocks ...
qemu exit code: 124 (outer timeout, expected when the guest deadlocks)
  PageCacheResizeBegin @ 6286345009
  ExfatResizeAllocation @ 6286360317
CR2-CLAIM-B: CONFIRMED (runtime trace)
```

T0 (cached tail → no backend read) and T1b (ext2 → backend takes no inode lock) isolate the cause to the exFAT self-lock on the backend read; a prior independent run of the same scenario hung identically.

**REPRODUCED checklist:**
1. **Level 0 alone triggered it** — yes: mount/write/fsync/umount/mount/open/pwrite64, no failpoints, no injected delays.
2. No Level 2/3 used — the pre-condition (uncached tail page, unaligned EOF) is reached by the trivial real-API sequence above (umount/remount drops the cache; equally reachable via O_DIRECT `invalidate_range` or a pre-existing file on the image).
3. **Real consumer**: any process issuing an extending buffered write on an exFAT file whose tail page is uncached — the syscall hangs permanently (demonstrated: guest worker thread stuck in `pwrite64`; consequence is live, not argued-only).
4. **Permanent**: the task sleeps on the `RwMutex` wait queue waiting for its own write guard; no sync/guard/resend can ever resolve it, and the held fs lock wedges subsequent exFAT operations. Not transient, not masked.

## Recommendation

- Fix the defect (not just the docs): in exFAT `write_at`/`write_direct_at`, perform the extension `page_cache.resize` (or at least its tail `fill_zeros`) before taking `self.inner.write()`, or use the upread→upgrade pattern like `write_direct_at`'s flush workaround, so the backend read never runs under the write guard.
- Correct the `PageCache::resize` doc: extension tail-clearing is fallible and may invoke the backend; drop "cannot return an error".
- Correct or delete the stale exFAT ordering comment (inode.rs:138-139): shrink order in code is page-cache-first, matching the `PageCache::resize` contract; extension order in exFAT (cache before size publication) contradicts the `PageCache::resize` "Size Synchronization" section — reconcile one rule across subsystems.
- Severity: raise from Medium to High — unprivileged permanent kernel-thread hang (denial of service) on a supported filesystem.

---
