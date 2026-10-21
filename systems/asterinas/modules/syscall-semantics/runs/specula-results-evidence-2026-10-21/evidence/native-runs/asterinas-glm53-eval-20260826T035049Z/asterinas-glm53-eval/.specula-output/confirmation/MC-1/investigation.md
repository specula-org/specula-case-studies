# MC-1 Investigation — A Later readv Fault Can Hide a Positive Copy Prefix

Worktree: `.specula-output/confirmation/MC-1/worktree` (baseline d0139a1 = upstream
604948581 + committed trace instrumentation; content identical to the harness-built
`$RUN/source` tree, verified by `diff -rq`).

## Step 1: Code audit

### Cited sites, verified

1. **`ostd/src/mm/io/mod.rs:332-362` (`impl_read_fallible`)** — `read_fallible` copies via
   `memcpy::<Dst, Src>` and on a partial copy returns `Err((Error::PageFault, copied_len))`
   (line 358). The number of bytes that physically landed in user memory *is* available to
   callers. `memcpy` for fallible destinations dispatches to `__memcpy_fallible`
   (`ostd/src/mm/io/copy.rs:181-190`), an x86-64 asm routine with exception-table fixup
   (`ostd/src/arch/x86/mm/util.rs`, `memcpy_fallible.S`) that recovers from page faults and
   returns the count of bytes NOT copied. So a positive prefix genuinely reaches user
   memory before the fault. Not model fiction.

2. **`kernel/core/src/error.rs:209-213`** — `impl From<(ostd::Error, usize)> for Error {
   fn from(ostd_error: (ostd::Error, usize)) -> Self { Error::from(ostd_error.0) } }` with
   comment "Used in fallible memory read/write API". **Drops the copied count.** This is
   the progress-erasure point the finding names.

3. **`kernel/core/src/vm/page_cache/vmo/mod.rs:551-574` (`Vmo::read`)** — iterates file
   pages, `page.reader().skip(page_offset).read_fallible(writer)`; on `Err(tuple)` it does
   `let err = Error::from(tuple); return Err(err);` (line ~558). The writer cursor has
   already advanced by `copied_len`, and the data is in user memory, but the function
   returns a bare `Err(EFAULT)`.

4. **`kernel/core/src/fs/file/inode_handle.rs:280-330` (`InodeHandle::read`)** — cited
   line 298 = `let result = file_ops.read_at(*offset, writer, status_flags);` under the
   offset lock. `Ok(len) => *offset += len`; `Err(err) => ... Err(err)` — **shared offset
   untouched on error**, even for the bytes that were copied.

5. **`kernel/core/src/syscall/preadv.rs:133-190` (`do_sys_readv`)** — vector loop; cited
   line 168 ≈ `Err(_) if total_len > 0 => false` (breaks WITHOUT recording the error, so
   the syscall returns `Ok(total_len)` = earlier complete iovecs only). If the faulting
   iovec is the first (`total_len == 0`), `final_error` is set → `Err(EFAULT)` even though
   a positive prefix was copied.

6. **`kernel/core/src/syscall/pwritev.rs:115-190` (`do_sys_writev`)** — same loop shape
   for write; cited line 164 ≈ the `Err(_) if total_len > 0` arm.

### Call chain (readv, ramfs and ext2)

`do_sys_readv` (preadv.rs:133) → `FileLike::read` = `InodeHandle::read`
(inode_handle.rs:280, offset lock) → `FileOps::read_at`:
- ramfs: `RamInode::read_at` (`fs/fs_impls/ramfs/fs.rs:695`) → `page_cache.read(offset, writer)?`
- ext2: `Inode::read_at` → `InodeInner::read_at` (`fs/fs_impls/ext2/inode/file.rs:228`) →
  `page_cache().read(offset, writer)?`
→ `PageCache::read` (`vm/page_cache/mod.rs:344`) → `Vmo::read` (`vmo/mod.rs:551`) →
per-page `read_fallible` → on fault `Err((PageFault, copied))` → `Error::from(tuple)`
(count dropped) → error unwinds through `page_cache.read?`, `read_at?`, InodeHandle
(offset NOT advanced) → vector loop drops the error (later iovec) → `Ok(earlier_total)`.

### Write side (committed-data form)

ramfs `RamInode::write_at` (fs.rs:735): expands `inode_meta.size` to the requested end
BEFORE the copy, then `page_cache.write(offset, reader)?` — per-page commits; on a
mid-copy fault the already-written dirty pages and the expanded size REMAIN (no
rollback). ext2 `InodeInner::write_at` (file.rs:255): `prepare_write` → `page_cache
.write` → on fault `rollback_write` (discards the prefix). So the writev committed-prefix
form is live on ramfs; ext2 discards (different, also non-Linux, shape).

### Reachability / trigger scenario (concrete)

All through the public syscall interface, single-threaded, deterministic:

1. `open("/tmp/f", O_RDWR)`; populate 3 pages with a pattern; offset 0.
2. `mmap` 2 pages; touch/fill page 0; `mprotect(page1, PROT_NONE)`.
3. `iov[0] = {valid_16_bytes, 16}`; `iov[1] = {map + PAGE/2, PAGE}` (2048 valid bytes,
   then the PROT_NONE page).
4. `readv(fd, iov, 2)`:
   - iov[0]: `Ok(16)`, offset 0→16.
   - iov[1]: `read_at(16, …)` copies file[16..2064) into user memory (2048 bytes),
     faults at the PROT_NONE page, `Err((PageFault, 2048))` → count dropped →
     `Err(EFAULT)` → offset unchanged (16) → loop breaks, error swallowed →
     **`readv` returns 16**.
5. Observable: return value 16, `lseek(fd,0,SEEK_CUR)` = 16, but user memory at
   `map+PAGE/2` holds correct file data file[16..2064). User memory contains 2064 newly
   copied bytes; return value and offset report 16. Linux returns the short read 2064
   and advances the offset to 2064. A subsequent `read` re-delivers file[16..] — the
   same bytes already sitting beyond `ret` in the faulting iovec.

First-iovec variant (same mechanism, `total_len == 0`): readv returns −1/EFAULT although
a positive prefix was copied (this is exactly the vector form of upstream issue #711's
scalar PoC). writev variant on ramfs: the 2048-byte prefix is committed to the file
beyond the 16-byte return value (verified shape from the modeling-phase capture below).

### Safeguards encountered

- `VmWriterArray::from_user_io_vecs` (kernel/core/src/util/iovec.rs:127-175) performs NO
  upfront page validation of user buffers — mid-copy faults are reachable, not filtered.
- No downstream mechanism reconciles user memory / page cache with the understated
  return value or stale offset. The syscall layer (PR #2230's `Err(_) if total_len > 0`)
  actively converts the fault into a plausible-looking short result.
- ext2's `rollback_write` only discards the *write* prefix; it does nothing for reads.

## Step 2: Developer knowledge

- Worktree git history is a single squashed baseline commit; no local blame available.
- Upstream **PR #2230** (commit 513532f, merged 2025-07-02) "Fix partial writes and reads
  in writev and readv" introduced the `Err(_) if total_len > 0 => break` arm — it
  addressed *inter-iovec* partial success (return the earlier total instead of an
  error). It did NOT touch the mid-iovec copied-prefix erasure at `error.rs:209` /
  `vmo/mod.rs`, nor the offset handling for the faulting iovec.
- Source TODO comments in preadv.rs/pwritev.rs acknowledge missing *vector atomicity*
  (a different, documented limitation), not progress erasure.
- Modeling-phase trace capture (real guest, this tree, 2026-08-26,
  `.specula-output/harness/build/logs/ramfs_fault_vector.qemu.log`):
  `SPECULA_RESULT ramfs_fault_vector writev=4096 errno=0 write=4096 errno=0` —
  writev with iov[1] = 2048-byte-valid prefix + PROT_NONE returned exactly 4096
  (= iov[0] only), errno 0, while the trace events show the 2048-byte prefix committed
  (the "trace-valid writev capture" the finding cites). Real-system corroboration of
  the syscall-level shape.

## Step 3: Known status / precedent

- **Upstream issue #711 "Wrong behavior when EFAULT occurs in the middle of I/O system
  calls" — OPEN (reopened), unfixed** (https://github.com/asterinas/asterinas/issues/711).
  2024 PoC: scalar `read(fd, buf, 2)` with a 1-valid-byte buffer → Linux returns 1,
  Asterinas returned EFAULT (and stale offset consequences for subsequent reads/writes).
  Maintainer lrh2000's 2026-07-14 comment: "the page cache implementation does not allow
  partial reads/writes", citing `kernel/src/vm/page_cache/vmo/mod.rs` L415/L547 — the
  same tuple-drop site this finding cites; priority "very low", no fix PR.
- Issue #1554 (pipe atomicity) is a different subsystem/aspect (context only per brief).
- GitHub searches (issue+PR, open and closed, updated desc): "readv/writev in title",
  "EFAULT iovec", "partial copy offset fault", "PRs touching preadv", "EFAULT read" —
  no other report of this mechanism; no fix landed recently (latest related PRs
  #3086/de52fd1/d7cbd0f are positional-I/O errno changes).

**Novelty: KNOWN (cite: https://github.com/asterinas/asterinas/issues/711; fix-status:
unfixed).** #711 reports the same mechanism (fallible-copy partial progress discarded →
error without short-count, page-cache VMO cited as the site) with scalar read/write
PoCs; MC-1's counterexample is the vectored/shared-offset instance of it. Note the
modeling brief already lists #711 as mechanism context, not a new finding.

**Pre-filter:** finding is MC-sourced WITH an actual counterexample
(`spec/output/MC_hunt_s1_partial_progress_bfs.out`, invariant `MCReadReturnCoversCopies`
violated: copied=3 > reported=2, sharedOffset=2, trace `MCDoSysReadvBegin(t1)` →
`MCVmoRead(t1,"Complete")` (iov1) → `MCVmoRead(t1,"Prefix")` (iov2, entryCopied=1) →
tuple conversion → EFAULT → Done with reported=2). MC-found + counterexample →
proceeds to Phase 2 regardless of KNOWN status.

## Phase 2 plan

Level 0 (pure public API, deterministic, no timing help): guest C program via the
standard regression-test plumbing (`test/initramfs/src/regression/io/file_io/`), built
into the initramfs by the existing Nix fileset glob (wildcard `*.c`), executed as init
via a new `AUTO_TEST=mc1repro` Makefile entry (harness plumbing only; kernel logic
untouched). Cases: (A) readv later-iovec prefix fault on /tmp (ramfs) and /ext2;
(B) readv first-iovec prefix fault; (C) writev later-iovec committed prefix (ramfs;
ext2 observed too). Build/run in the Docker dev image with /dev/kvm, reusing the
warm `target/` and initramfs build caches from the modeling-phase run (same tree
content, same toolchain — provenance verified by diff).

## Phase 2 log (running record)

- **Linux control** (host 7.1.9, same program): see `linux-control.txt`. readv_later
  ret=2064/offset=2064 (short read covers the 2048-byte copied prefix), readv_first
  ret=2048 (no EFAULT), writev_later ret=2064 + 2048 committed. Follow-up read does
  NOT re-deliver the prefix.
- **Guest run 1** (task b8c602e96): booted the v1 program whose `untouched_ok` scan
  read into the PROT_NONE page from USERSPACE → the test process itself segfaulted
  after MC1_SETUP (test bug, fixed; prefix must end exactly at the page boundary so
  there is no untouched tail to scan). Guest output ended at `MC1_SETUP` — consistent
  with PID-1 SIGSEGV → guest exit; make grep failed as designed.
- **Guest run 2** (task b01e7b759): nix rebuilt `io/file_io/specula_repro_mc1` from the
  fixed program (build log shows `CC <= .../io/file_io/specula_repro_mc1`); boot OK,
  but console STILL ended at `MC1_SETUP` with no MC1_CASE output and no panic text.
  Host run of the identical binary is clean, so the death is guest-specific and
  happens before the first case's printf — inside the first faulting readv, the
  mprotect/mmap setup, or pattern-file prep (all of which the host handles fine).
- **Guest run 3** (task b03c7d2e6): program instrumented with unbuffered stdout and
  MC1_STEP markers around every syscall to localize the silent death.
- **Guest run 4 — REPRODUCED** (this session, bg task b5efddd18, 2026-08-27, `guest-run.txt`,
  worktree `qemu.log`): v4 program (raw `write()` output, fork-isolated phases, sanity
  gates) built into the initramfs (nix `CC <= .../io/file_io/specula_repro_mc1`), kernel
  rebuilt incrementally against the warm `source/target` cache (symlink
  `worktree/target -> ../../../../source/target`), booted under KVM, ran to
  `MC1_REPRO_DONE`; `make`'s own `MC1_REPRO_DONE` grep passed, DOCKER_EXIT=0. The v2-era
  "silent death at MC1_SETUP" did not recur — v4 completed every phase on both filesystems,
  so it was an output-buffering/PID-1 artifact, not a kernel limitation.

  Results (guest Asterinas vs host Linux, same program, page_size=4096, unit=2048):
  - `readv_later` (the CE scenario): **ret=16 errno=0 offset=16** while
    `prefix_copied_beyond_ret=1` (2048 file bytes sit in iovec 1 beyond the reported count)
    and the follow-up read **re-delivers the same 2048 bytes** (`redelivers_prefix_bytes=1`).
    Linux: ret=2064 errno=0 offset=2064, follow-up does NOT re-deliver (control re-run this
    session via `repro/mc1_repro_host2`). Divergence identical on ramfs (/tmp) and ext2 (/ext2).
  - `readv_first` (total_len==0 form): **ret=-1 errno=14 (EFAULT) offset=0** while
    `prefix_copied_despite_efault=1` (2048 bytes copied). Linux: ret=2048 errno=0 offset=2048.
  - `read_scalar` (#711 scalar form): ret=-1 errno=14 offset=0, `prefix_copied=1`; Linux
    ret=2048 offset=2048. Both fs types.
  - `writev_later` (committed-data form): **ret=16 errno=0 offset=16** while
    `committed_prefix_bytes=2048` (verified by pread) — on BOTH ramfs and ext2. Note: ext2's
    `rollback_write` (ext2/inode/file.rs:206) is a no-op when `end <= old_size` (in-place
    write into a large file), so the committed prefix survives there too. Linux: ret=2064.

  Right-bug check vs the CE (`MC_hunt_s1_partial_progress_bfs.out`): same action sequence
  (readv begin -> iovec 1 `MCVmoRead Complete` -> iovec 2 `MCVmoRead Prefix` -> tuple
  conversion -> EFAULT -> syscall returns earlier-iovec total only), same violated invariant
  `MCReadReturnCoversCopies` (user memory holds 2064 new bytes, return value reports 16,
  shared offset 16), same root-cause chain (error.rs:209 tuple drop <- vmo/mod.rs
  read_fallible error <- inode_handle.rs offset-only-on-Ok <- preadv.rs:168
  `Err(_) if total_len > 0 => break`). Verified by `git diff` that the instrumentation patch
  is semantics-preserving on every cited site (upstream `read_fallible(writer)?` performs the
  identical `From<(ostd::Error, usize)>` count-dropping conversion), so the reproduced
  behavior is upstream behavior.

  Escalation level reached: **0** (public syscalls only, single thread, deterministic
  PROT_NONE fault; no timing help, no state injection, no logic patch).

## Round 3 (turn01_A re-confirmation, 2026-08-28 evening) — continuation record

The round-2 session died before emitting a canonical VERDICT (dispatcher error:
"output has no canonical VERDICT"), and its `guest-run-round2.txt` was never
written; the repro dir was reorganized (canonical repro file removed). This round
restores the artifacts and re-executes everything load-bearing.

### Phase 1 re-verification (round 3)

- Cited sites re-read in the worktree, mechanism chain confirmed verbatim:
  `ostd/src/mm/io/mod.rs:358` returns `Err((Error::PageFault, copied_len))` after
  the fallible memcpy already put the prefix bytes in user memory;
  `kernel/core/src/vm/page_cache/vmo/mod.rs:558` converts via `Error::from(tuple)`
  (count dropped; `kernel/core/src/error.rs:209-214` `From<(ostd::Error, usize)>`
  keeps only `.0`); `kernel/core/src/fs/file/inode_handle.rs:280-330` advances
  `*offset` only on `Ok`; `kernel/core/src/syscall/preadv.rs:167-180` breaks on
  `Err(_) if total_len > 0` → `Ok(total_len)` (earlier iovecs only), and sets
  `final_error` (EFAULT) when the faulting iovec is the first; `pwritev.rs:163-176`
  same shape. `error.rs` is NOT in the worktree's modified-file list — the
  tuple-drop is pristine upstream code.
- Instrumentation integrity re-verified: `git diff` (19 files, +387/−66) shows the
  preadv.rs restructuring maps 1:1 onto upstream arms (`Err(_) if total_len > 0
  => break` ≡ `false`; `Err(err) => return Err(err)` ≡ `final_error` + `result`,
  with `on_access` still gated `is_ok_and(len > 0)`); every `tla_trace::*` hook
  funnels through `with_trace_mut` and gates on a per-thread phase state machine
  that only activates for `.specula_*` trace files (`trace_file_for_path`, line
  268) — pure observers on the repro's `/tmp/mc1_*` and `/ext2/mc1_*` paths.
- CE re-read: final state t1 `copied=3, committed=3, reported=2,
  offsetAdvanced=2, entryStatus=EFAULT, result=Ok`, sharedOffset=2, invariant
  MCReadReturnCoversCopies violated — structurally identical to the repro's
  copied=2064 / reported=16 / offset=16 / EFAULT-swallowed-to-Ok(16).
- **Known-status re-check (fresh, round 3)**: issue #711 fetched directly —
  OPEN (reopened), P4, no "Closed by pull requests", latest comment lrh2000
  2026-07-14: "we do not allow partial reads or writes in our page cache
  implementation … priority to fix this is very low", citing the vmo/mod.rs
  fallible sites. Fresh GitHub PR sweep (issues + merged/closed PRs): 513532f
  (#2230, 2025-07-02) fixed only the inter-iovec form; 2026 PRs #3086/de52fd1/
  d7cbd0f (positional-I/O errno), #2953/#3256 (page-cache refactor / uninit-memory
  leak), #2958 (MMIO asm), #2766 (MM syscall errnos), #2855 (/proc/pid/mem) — none
  touch the mid-iovec copied-prefix erasure. Novelty stays **KNOWN (cite:
  https://github.com/asterinas/asterinas/issues/711; fix-status: unfixed)**;
  MC-sourced with an actual counterexample → Phase 2 proceeds (no DROPPED).

### Phase 2 re-execution (round 3)

- Canonical repro restored: `repro/test_bugMC-1_readv_prefix_fault.c` (4-line
  provenance header + guest copy byte-identical body, verified by diff).
- **Linux control executed this round** (gcc -Wall -O2, host Linux 7.1.9):
  readv_later ret=2064 errno=0 offset=2064, `prefix_copied_beyond_ret=1`,
  `stopped_at_fault=1`, next_read=4096, `redelivers_prefix_bytes=0`; readv_first
  ret=2048 errno=0 offset=2048; read_scalar ret=2048 offset=2048; writev_later
  ret=2064 offset=2064 committed_prefix_bytes=2048. Linux returns the short count
  covering the prefix and advances the offset by it — the contract, matching the
  prior rounds' controls exactly.
- **Guest Asterinas run** (docker asterinas/dev:0.18.1-20260805, /dev/kvm, warm
  12G `source/target` cache via worktree symlink, bg task bb711beda):
  `make run_kernel AUTO_TEST=mc1repro TARGET_ARCH=x86_64 SMP=2 MEM=2G
  ENABLE_KVM=1 QEMU_HOSTFWD=off CONSOLE=hvc0 LOG_LEVEL=error
  INITRAMFS_SKIP_GZIP=1`. **Completed: DOCKER_EXIT=0, MC1_REPRO_DONE**
  (86 MC1_ lines in worktree/qemu.log; captured at `guest-run-round3.txt` and
  `repro/test_bugMC-1_readv_prefix_fault.guest_output.log`). Divergence vs the
  same-program Linux control, identical on ramfs (/tmp) and ext2 (/ext2):
  - `readv_later` (the CE scenario): guest **ret=16 errno=0 offset=16** with
    `prefix_copied_beyond_ret=1` (2048 file bytes in iovec 1 beyond ret) and
    `redelivers_prefix_bytes=1` (follow-up read re-delivers them; next_read=4096).
    Linux: ret=2064 errno=0 offset=2064, redelivers_prefix_bytes=0.
  - `readv_first` (total_len==0 form): guest **ret=-1 errno=14 offset=0** with
    `prefix_copied_despite_efault=1`. Linux: ret=2048 errno=0 offset=2048.
  - `read_scalar` (#711 scalar form): guest ret=-1 errno=14 offset=0,
    prefix_copied=1. Linux: ret=2048 offset=2048.
  - `writev_later` (committed-data form): guest **ret=16 offset=16** with
    `committed_prefix_bytes=2048` (pread-verified; ext2 rollback_write no-op
    for in-place writes, end <= old_size — file.rs:206). Linux: ret=2064
    offset=2064.
  Right-bug check vs `MC_hunt_s1_partial_progress_bfs.out`: same action
  sequence (readv begin → iov1 MCVmoRead Complete → iov2 Prefix → tuple
  conversion → EFAULT → error swallowed, earlier-iovec total returned), same
  violated invariant MCReadReturnCoversCopies (guest copied=2064 / reported=16
  / sharedOffset=16 ≡ CE copied=3 / reported=2 / sharedOffset=2), same
  root-cause chain. Escalation level: **0** (public syscalls, single thread,
  deterministic PROT_NONE fault; no timing help, no state injection, no logic
  patch; instrumentation verified semantics-preserving and inert on the
  repro's paths).

## Round 2 (turn01_A re-confirmation, 2026-08-28) — continuation record

Prior round (turn01_A + turn02_B challenge) concluded REPRODUCED; this round
independently re-verifies the load-bearing claims and re-executes the
reproduction.

### Phase 1 re-verification (this round)

- Cited sites re-read in the worktree; mechanism chain re-confirmed verbatim:
  `read_fallible` returns `Err((Error::PageFault, copied_len))`
  (ostd/src/mm/io/mod.rs:358) after the x86-64 exception-table `rep movsb`
  (memcpy_fallible.S) has already put the prefix bytes in user memory;
  `Vmo::read` converts via `Error::from(tuple)` and drops the count
  (kernel/core/src/vm/page_cache/vmo/mod.rs:558, kernel/core/src/error.rs:209);
  `InodeHandle::read` advances the shared offset only on `Ok`
  (kernel/core/src/fs/file/inode_handle.rs:301-313); `do_sys_readv` breaks on
  `Err(_) if total_len > 0` and returns the earlier-iovec total
  (kernel/core/src/syscall/preadv.rs:167-180); `do_sys_writev` has the same
  shape (kernel/core/src/syscall/pwritev.rs:163-176). Scalar `sys_read`
  (kernel/core/src/syscall/read.rs:31-33) hits the identical collapse via
  `file.read`. `VmWriterArray::from_user_io_vecs` performs no upfront page
  validation (kernel/core/src/util/iovec.rs:129-175) — mid-copy faults are
  reachable through plain syscalls.
- Counterexample re-read: `spec/output/MC_hunt_s1_partial_progress_bfs.out`,
  invariant MCReadReturnCoversCopies violated; final state copied=3,
  committed=3, reported=2, offsetAdvanced=2, entryStatus=EFAULT, result=Ok;
  trace readv begin → iov1 MCVmoRead "Complete" → iov2 MCVmoRead "Prefix"
  (entryCopied=1, effectLog entry start=2 amount=1) → tuple conversion → Done.
- **Known-status re-check (fresh, this round)**: GitHub issue #711 "Wrong
  behavior when EFAULT occurs in the middle of I/O system calls" fetched
  directly (https://github.com/asterinas/asterinas/issues/711): OPEN
  (reopened), last updated 2026-07-14 by lrh2000 — "It seems that we do not
  allow partial reads or writes in our page cache implementation … priority
  to fix this is very low", citing kernel/src/vm/page_cache/vmo/mod.rs L415/L547
  (the read/write fallible sites behind this finding's tuple drop). No fix PR
  ("Closed by pull requests": none). Fresh GitHub searches (issues + PRs,
  incl. recently merged/closed: 513532f/#2230 readv/writev inter-iovec partial
  success; #3086/de52fd1/d7cbd0f positional-I/O errno; #2953/#3256 page-cache
  refactor; #2948 volatile asm) show NO report or fix of the mid-iovec
  copied-prefix collapse other than #711's mechanism. Novelty stays
  **KNOWN (cite: https://github.com/asterinas/asterinas/issues/711;
  fix-status: unfixed)**; MC-sourced with an actual counterexample → Phase 2
  proceeds regardless (no DROPPED for MC).

### Phase 2 re-execution (this round)

- Artifact preflight before reuse: `source` and worktree tracked diffs are
  byte-identical (cmp of full `git diff` output: 19 files, +387/−66,
  instrumentation + mc1repro plumbing); harness instrumentation files
  (tla_trace.rs, specula_trace.c/.sh) cmp-identical in both trees;
  `specula_repro_mc1.c` byte-identical between source, worktree, and
  `.specula-output/repro/test_bugMC-1_readv_prefix_fault.c`. Warm 8.5G
  `source/target` cargo cache was built from this exact content (prior round
  verified `diff -rq` tree identity; same RUSTUP_TOOLCHAIN as harness
  run.sh). Recreated `worktree/target → ../../../../source/target` symlink.
- Canonical repro file written:
  `.specula-output/repro/test_bugMC-1_readv_prefix_fault.c` (v4 program,
  byte-identical to the guest's initramfs build input).
- **Linux control executed this round** (gcc -Wall -O2 on the host, Linux
  7.1.9; output at `.specula-output/repro/mc1_linux_control_thisround.txt`):
  readv_later ret=2064 errno=0 offset=2064, follow-up read does NOT re-deliver
  (redelivers_prefix_bytes=0); readv_first ret=2048 errno=0; read_scalar
  ret=2048; writev_later ret=2064 with 2048 committed. Linux returns the short
  count covering the prefix and advances the offset by it — the contract.
- **Guest Asterinas run** (docker asterinas/dev:0.18.1-20260805, /dev/kvm,
  `make run_kernel AUTO_TEST=mc1repro TARGET_ARCH=x86_64 SMP=2 MEM=2G
  ENABLE_KVM=1 CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1`, bg task
  bae39fff5): see `guest-run-round2.txt` for the captured output.
