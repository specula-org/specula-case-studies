# AST-01..09 independent validation (2026-09-02)

Scope: classify each AST finding and re-check it against Linux and against
Asterinas at the tested pin. Read-only intake: no source changed in any tracked
checkout, no issue filed, nothing pushed. All kernel-side runs used a throwaway
git worktree of the pinned commit; the tooling-only deltas applied there are in
`scratch-worktree-tooling.diff` (Makefile init hook, OVMF path, test subdir,
ktest module registration). The findings' own reproducers were used unmodified.

## Identity

| Item | Value |
|---|---|
| Asterinas revision under test | `604948581512d83734377974d4c34adb4530f2d7` (`v0.18.1-18-g604948581`) |
| Current `upstream/main` at check time | `29b0f4bcf111efb590ee14768c624ecf1e81bbd7` (2026-09-01, 49 commits after the pin) |
| Linux control | host kernel Linux 7.1.9 (NixOS, x86_64, SMP PREEMPT_DYNAMIC); tmpfs = `/dev/shm`, disk fs = ext4 (no ext2 mount on host) |
| Guest runtime | QEMU 10.2.1 (nix devshell), KVM, SMP=2, 8G, OVMF, grub-rescue-iso, initramfs regression build |
| ktest runtime (AST-07/08) | QEMU 10.2.1, TCG (no KVM), SMP=2, 8G, qemu-direct |
| Toolchain | rustc nightly-2026-07-21 (matches pin); guest test binaries: nix gcc 14.2.1, static glibc; host control binaries: gcc 15.3.0 |
| Binary identity | Linux and Asterinas ran separately compiled builds of the same `repro.c` (not one identical binary) |

## Validation steps (handoff "Required handling")

| Step | Result |
|---|---|
| Resolve current `upstream/main` | PASS (`git fetch upstream main` -> `29b0f4bcf`) |
| Reopen every decisive source path at `604948581` | PASS (all anchors read; mechanisms confirmed, see per-finding table) |
| Reopen every decisive source path at `29b0f4bcf` | PASS: `vmo/mod.rs`, `error.rs`, `ext2/inode/file.rs`, `preadv.rs`, `pwritev.rs`, `read.rs`, `write.rs`, `pread64.rs`, `pwrite64.rs`, `segment.rs`, `dma/util.rs` byte-identical to the pin; `inode_handle.rs` changed only in field order + `sync()` (offset logic unchanged, now lines 294-325); `ramfs/fs.rs` refactored (devtmpfs/tmpfs moves) but `read_at`/`write_at` logic unchanged (now lines 984-1045); `ostd/mm/io/mod.rs` changed only in the `debug_assert!` of `from_user_space` |
| Search open/closed issues and PRs for duplicates and fixes | PASS (GitHub search API, 2026-09-02; see "Upstream status") |
| Linux control re-run | PASS, all 7 userspace reproducers (`logs/linux-7.1.9-*.txt`) |
| Asterinas guest re-run at `604948581` | PASS, all 7 userspace reproducers reproduced (`logs/asterinas-604948581-guest-transcript.txt`) |
| AST-07 ktest re-run at `604948581` | RUN: wrong-answer flavours REPRODUCED; kernel-death flavour NOT REPRODUCED (kernel survived) |
| AST-08 ktest re-run at `604948581` | RUN: REPRODUCED (both required conditions true, 0 IOTLB flushes) |
| Runtime re-run on `29b0f4bcf` | NOT RUN (static inspection only; decisive code identical or logic-equivalent) |
| Filing / commenting / pushing | NOT DONE (not authorized) |

## Per-finding results

Classification vocabulary: **compat** = Linux-visible syscall compatibility /
data-consistency bug; **hard-fault** = kernel-internal hard fault; **dma** = DMA
lifetime / memory-safety bug.

| ID | Class | Linux 7.1.9 (this run) | Asterinas 604948581 (this run) | Pin static | main static | Panic? |
|---|---|---|---|---|---|---|
| AST-01 | compat (ext2 write) | ret=short count, offset delta = committed (`CONSISTENT_SHORT_WRITE` x3) | `ret=-1 EFAULT`, committed=4096/128/128 (buffered + O_DIRECT), offset delta 0, `DIVERGES_FROM_LINUX` | confirmed | identical | no |
| AST-02 | compat (ramfs size) | deviations=0 | deviations=5; CASE A/B/C size 8192->16384, CASE E 8192->12288, CASE D 8192->24576 (Linux 16384); CASE A survives close/reopen | confirmed | logic identical (moved lines) | no |
| AST-03 | compat (readv/writev atomicity) | A/B/C 0 torn, D (scalar-loop control) 100/100 torn | A 87/100, B 87/100, C 98/100 torn (191168 foreign bytes inside writev spans), D 99/100, E under-reports (ret=4096, deposited 8192) | confirmed (TODO comment admits it) | identical | no |
| AST-04 | compat (read prefix EFAULT; #711 mechanism) | ret=128, offset 128, next read sees `Y` | ret=-1 EFAULT with 128 bytes delivered, offset 0, next read replays `A`; 6 anomalies on ramfs+ext2 | confirmed | identical | no |
| AST-05 | compat (ramfs read past EOF) | 0/0 | wrong_return_values=0, buffers_modified_past_return=6/6 | confirmed (no `writer.limit`) | logic identical | no |
| AST-06 | compat (O_APPEND offset on fault) | bugs=0 on ext4 and tmpfs | bugs=2 on ext2 and on ramfs: offset 0->4096 after EFAULT, dup'd read returns 0 | confirmed | identical (`*offset = self.path().size()` before the fallible write, line 321) | no |
| AST-07 | kernel-internal unsoundness; **hard fault not reproduced here** | n/a | see below | confirmed | identical | no Rust panic, no CPU exception, no kernel death observed |
| AST-08 | dma (stale IOTLB use-after-free) | n/a | REPRODUCED, see below | confirmed | identical (FIXME still at `dma/util.rs:312`) | no; test fails by assertion, kernel keeps running |
| AST-09 | compat (SA_RESTART on pipe readv/writev) | 5/5 PASS | checks 2 and 4 FAIL (`errno=4`), scalar controls PASS | confirmed | identical (0 `ERESTARTSYS` in the four wrappers) | no |

Numbers for AST-03 differ from the handoff's single preserved run (79/92/97) as
expected for a schedule-dependent race; the detector control (CASE D) tore on
both kernels, so the detector was live in both runs.

## AST-07 detail (answers "is it a real panic?")

Four ktests, each in its own boot, QEMU `-d int,cpu_reset,guest_errors`
enabled (TCG, so exception logging is authoritative):

| Test | Result | Reading |
|---|---|---|
| `round_trip_matrix` | FAILED (assert) | `empty@end` round trip returns `Err` for n=1 and n=2; `empty@start` and non-empty control OK. Deterministic wrong answer, reproduced. |
| `answers_from_a_foreign_frame` | FAILED (assert) | `adjacency=obtained`, `round_trip_ok=false`, `accepted_as_usegment=true`; controls correct. Typed frames accepted as `USegment`, reproduced. |
| `at_end_boundary_faults` | FAILED (assert) | `from_in_use=Err(Unused)`, `about_to_call`, then **`CR11\|fault\|survived\|round_trip_ok=false`**. The kernel tolerated the read. QEMU logged 1012 hardware interrupts (all `v=21`) and **zero CPU exceptions** (no #PF/#GP/#DF, no triple fault). |
| `max_tracked_boundary_probe` | ok | `max_paddr=0x280000000`, allocator never reaches it (`reaches_max_paddr=false`), so the `debug_assert`-guarded variant is unreachable here too. |

Conclusion: at `604948581` in this environment the defect is a real
unsoundness with observable wrong results (identity broken, typed segment
accepted as untyped), but neither a Rust panic nor a kernel death occurred. The
package's own falsification criterion ("`CR11|fault|survived` appears: the
hard-fault claim fails, the wrong-answer claim could still stand") is met.
The original run's "kernel death" (at `4c1fdd1e4`, 128 MiB `max_paddr`) is
therefore environment-dependent: it needs the one-past-the-end `MetaSlot` to
hold a `vtable_ptr` that was never written since boot; here the neighbouring
slot held a stale but callable vtable. Do not describe AST-07 as a panic, and
do not describe it as reliably killing the kernel either. Describe it as an
unsound read whose outcome depends on the neighbouring frame's metadata slot.

## AST-08 detail

Single ktest under `-device intel-iommu,intremap=on,device-iotlb=on` plus
`-device edu`, vtd tracing on:

```
CR20| phase 1: mapped DmaCoherent daddr=0x3fffffe000 -> paddr=0x9166000
CR20| phase 2: dropped the DmaCoherent (unprepare_dma -> iommu::unmap, no IOTLB flush), frame 0x9166000 is back in the allocator
CR20| phase 2: frame 0x9166000 is now an ordinary kernel allocation holding 5a5a...
CR20| control: device wrote to never-mapped daddr=0x403fffe000 (completed=true), witness frame now 5a5a...   (16 vtd_dmar_fault, IOMMU enforcing)
vtd_iotlb_page_hit IOTLB page hit sid 0x18 iova 0x3fffffe000 slpte 0x9166083 domain 0x0                     (after teardown)
CR20| phase 3: device wrote to the revoked daddr=0x3fffffe000 (completed=true), witness frame now d1d1...
CR20| SUMMARY witness_intact_after_control=true witness_clobbered_after_replay=true
vtd events: page_update 1, page_hit 2, reset 0, inv_desc_iotlb_{global,domain,pages} 0
```

Both required conditions hold; zero invalidations over boot plus test.
Reproduced at `604948581` (previously only at `4c1fdd1e4`). The kernel did not
panic; the ktest fails by its own assertion. Attacker model unchanged:
DMA-capable device or vIOMMU cache, not an unprivileged process.

## Upstream status (searched 2026-09-02)

| Finding | Related items | Effect |
|---|---|---|
| AST-01, AST-04 | issue #711 (open, maintainer-confirmed 2026-07-14), count-erasure mechanism | AST-01 already submitted per user; do not re-file AST-04 as a new mechanism |
| AST-01 | PR #3297 (open draft) `InodeRollbackGuard` for ext2 | rolls back capacity/blocks on error; does not restore the dirty in-place prefix and does not restore the copied count (`error.rs:209-219` untouched), so not a fix |
| AST-01/04/05 | PR #3703 (open) multi-page I/O for `PageCacheBackend` | touches the `vmo/mod.rs` write path; not aimed at the fault path; unverified |
| AST-03 | PR #2230 (merged 2025-08) partial readv/writev; PR #3720 (merged 2026-08-27) iovec validation | neither adds per-call offset locking; TODO still in source |
| AST-06 | PR #3481 (open, updated 2026-08-28) "Fix inode append and memfd seal races" | moves append resolution into the fs (`WriteOffset::Append`); the `?` then precedes the offset update, so a failed append write would no longer move the shared offset. Would fix AST-06 as a side effect if merged; it also rewrites ramfs `write_at` (+201/-91), effect on AST-02 unverified |
| AST-07 | issue #3165 / PR #3587 (closed; wraparound in `Segment::slice`) | different mechanism; `<=` and the unconditional `from_raw` are unchanged on main |
| AST-08 | none (only #3474 RISC-V IOMMU tracking) | still only the `FIXME` comment; `ostd/src/arch/x86/iommu/invalidate` sets up queued invalidation but nothing invalidates the IOTLB on unmap |
| AST-09 | PR #3576 (open, updated 2026-07-23) "Refactor the syscall restart mechanism" | makes `pause_until*` return `ERESTARTSYS` directly and removes the per-syscall EINTR mapping; pipe readv/writev would restart under it. Would fix AST-09 if merged; not merged |

## Caveats

- Linux control ran on ext4 and tmpfs, not ext2. The contracts under test
  (write(2)/read(2) short counts, f_pos update, readv atomicity, SA_RESTART) do
  not depend on the disk fs, but AST-01's Linux column is ext4 evidence.
- Guest and host binaries are separate builds of the same source (nix gcc
  14.2.1 static vs host gcc 15.3.0), the same limitation as the original campaign.
- AST-07/08 ktests ran under TCG; the userspace guest ran under KVM.
- One guest boot per result set; AST-03 counts are one-run observations.
- Scratch worktree: `<scratchpad>/aster-pin`, registered in
  `~/Documents/asterinas-dev` as a linked worktree. Run `git worktree prune`
  there after the scratchpad is cleaned.

## Files

- `logs/asterinas-604948581-guest-transcript.txt`: full guest output of the 7 reproducers.
- `logs/linux-7.1.9-*.txt`: host control output per reproducer.
- `logs/ast07-ktest-*.txt`, `logs/ast07-driver-summary.txt`: AST-07 ktest boots.
- `logs/ast08-ktest-*.txt`, `logs/ast08-driver-summary.txt`: AST-08 ktest boot with vtd trace lines.
- `scratch-worktree-tooling.diff`, `run_ast_all.sh`, `ostd-OSDK.cr11.toml`, `ostd-OSDK.cr20.toml`: everything applied to the scratch worktree to run the above.

## Upstream issue search, second pass (2026-09-02, per finding)

Searched `repo:asterinas/asterinas` issues and PRs (open and closed) with
mechanism-specific keyword sets per finding, plus `git log --grep` on
`upstream/main` for `iotlb|invalidat|iommu`.

| Finding | Matching upstream issue? | Nearest items |
|---|---|---|
| AST-01 | partial: #711 (open) covers the dropped partial count, not the durable prefix/offset mismatch | PR #3297 (open draft, ext2 rollback guard) |
| AST-02 | none | none for "size published before copy"; PR #3481 rewrites ramfs `write_at` |
| AST-03 | none | PR #2230 (merged, partial readv/writev), TODO in source |
| AST-04 | yes: #711 (open, same mechanism) | do not re-file |
| AST-05 | none | PR #2953 (page cache refactor) did not add `writer.limit` to ramfs |
| AST-06 | none | PR #3481 (open) would fix as a side effect |
| AST-07 | none for the empty-segment path | #3165 / PR #3587 (closed, integer wrap in `Segment::slice`) |
| AST-08 | none | #237 (open, 2023, "Enable IOMMU to protect typed memory", generic); PR #961/#1218 (merged 2024) added queued invalidation but only for the interrupt entry cache; commit `9b3883615` invalidates the IEC on interrupt remap; no commit ever touched IOTLB invalidation on unmap |
| AST-09 | none | PR #3576 (open) would fix as a side effect; #1578 (closed) is the origin of the restart machinery |

Conclusion: only AST-04 (and the mechanism half of AST-01) has an upstream
issue. AST-08 has no issue and no PR; a fix PR is being drafted on branch
`fix/iommu-iotlb-invalidate` (scratch worktree, not pushed).

## AST-08 fix validation (branch `fix/iommu-iotlb-invalidate`, base `29b0f4bcf`)

Implementation: commit 1 (IOTLB invalidation) written by Codex from a written
handoff, reviewed line by line, then five cosmetic corrections applied
(dead `global()` constructor removed, `with_drain` rewritten, doc comments,
alignment `debug_assert`, redundant clone). Commit 2 (free the device address
range) written directly. Scratch worktree `<scratchpad>/aster-fix`; a second
scratch worktree `<scratchpad>/aster-base` at unpatched `29b0f4bcf` served as
the baseline. Nothing pushed.

| Check | Baseline `29b0f4bcf` | Commit 1 only | Commits 1+2 |
|---|---|---|---|
| CR-20 ktest (edu + vIOMMU, vtd trace) | FAILED: `witness_clobbered_after_replay=true`, 0 invalidations | ok: `witness_clobbered_after_replay=false`, `vtd_inv_desc_iotlb_pages 1`, 32 DMAR faults (16 control + 16 replay) | ok, same numbers |
| `cargo osdk test` ostd, plain QEMU (no IOMMU) | not run | 203 passed | not rerun (no IOMMU path involved) |
| `cargo osdk test` ostd under `-device intel-iommu` | not run | 203 passed, 15 page-selective invalidations, 0 DMAR faults | 203 passed, 15 invalidations, 0 DMAR faults (device address ranges now reused) |
| `./tools/format_all.sh --check` | n/a | PASS | PASS |
| `./tools/clippy_check.sh workspace` x86_64 / riscv64 / loongarch64 | n/a | PASS / PASS / PASS (Codex) | PASS / PASS / PASS |
| `make run_kernel SCHEME=iommu AUTO_TEST=regression` | hello_world ok; **network: `test_tcp_read_wrap_receive_buffer_tail` 2/46 failed** (suite aborts) | hello_world, network, time ok; **device: `setup_mount_nvme_ext2: mount('/dev/nvme0n1') failed: EINVAL`** | run 1: network + time ok, same NVMe EINVAL; run 2: same tcp wrap 2/46 failure as baseline |
| same, baseline with network suite skipped | hello_world, time ok; **device: same NVMe EINVAL** | | |
| same, network + nvme skipped (remaining suites: device, io, process, memory, ipc, intel_tdx, fs, security) | not run | not run | first attempt: guest hung in `/test/fs` after QEMU reported `vtd_fetch_inv_desc: detected invalid QI tail (tail=0x100, size=0x100)` (see below); after the queue-tail fix: **all suites passed** |

Reading of the regression rows: both failures seen under `SCHEME=iommu` are
independent of the patch. The NVMe ext2 mount returns `EINVAL` on unpatched
`main` in this environment (QEMU 10.2.1 `-device nvme`), and the TCP
receive-buffer-wrap test fails intermittently on both kernels with identical
short `send`/`recv` counts (timing dependent). Neither run produced an IOMMU
fault message from the kernel (`iommu: caught page fault` only appears in the
CR-20 control write).

### Bug found by the regression run: invalidation queue tail wrap-around

`Queue::append_descriptor()` (`ostd/src/arch/x86/iommu/invalidate/queue.rs`)
wrapped the tail only on the *next* append, so after the 256th descriptor
`tail()` returned 256 and the IQT register write was rejected; the completion
poll then spun forever. Unreachable on `main` (only interrupt-cache
invalidations use the queue), reached after 128 DMA teardowns with the fix.
Fixed in a preparatory commit (`tail = (tail + 1) % size`), and commit 2 now
carries a ktest (`dma_teardown::survives_invalidation_queue_wrap`, 1024
teardowns). Final branch (3 commits) validation:

| Check | Result |
|---|---|
| `./tools/format_all.sh --check` | PASS |
| `./tools/clippy_check.sh workspace` x86_64 / riscv64 / loongarch64 | PASS / PASS / PASS |
| CR-20 ktest (edu + vIOMMU) | ok, `witness_clobbered_after_replay=false`, 1 page-selective invalidation |
| `cargo osdk test` ostd, plain QEMU | 204 passed |
| `cargo osdk test` ostd under `-device intel-iommu` | 204 passed, 1039 page-selective invalidations (queue wrapped 4 times), 0 DMAR faults |
| `make run_kernel SCHEME=iommu AUTO_TEST=regression`, network + nvme skipped | hello_world, time, device, io, process, memory, ipc, intel_tdx, fs, security: all passed (`All regression tests passed.`) |

Patches: `../asterinas-bug-findings-2026-08/upstream-issues/AST-08-patches/`.
Final commits on `fix/iommu-iotlb-invalidate`:
`d370078dd` queue tail, `9f338d737` IOTLB invalidation, `bfef1ca11` free daddr.

Codex handoff, result and logs: `<scratchpad>/codex-handoff-slice1.md`,
`<scratchpad>/logs/cr20-fix/*.log`, `<scratchpad>/logs/fix-validate*/`;
copies of the decisive logs are in `logs/ast08-fix-*.txt`.

## AST-05 fix validation (branch `fix/ramfs-read-past-eof`, base `51c59734e`)

Filed upstream by the user on 2026-09-02 as
https://github.com/asterinas/asterinas/pull/3778 (open at time of writing).

Two commits: `aba0bfe41` "Limit page-cache reads to the file size in ramfs and
exfat" (virtiofs pattern: `clone_exclusive()` + `limit(read_len)` + `skip(read_len)`,
skipped when `read_len == 0`, in `RamInode::read_at` and `ExfatInode::read_at`)
and `0f7389044` "Add a regression test for reads that reach EOF"
(`fs/read_eof/read_eof.c`, runs on `/tmp`, `/ext2`, `/exfat`). An earlier
version used an in-place `writer.limit()` like ext2; it was validated the same
way (single commit `f507a2165`) and then replaced because the in-place limit
leaves `writer.avail() == 0`, which defeats `do_sys_readv`'s EOF check. exfat was added after the AST-05 reproducer was
run against `/exfat` on `604948581` and failed the same way (ext2 passes:
`logs/ast05-fix-read_eof-baseline-604948581.txt`). Patch:
`../asterinas-bug-findings-2026-08/upstream-issues/AST-05-patches/`. Not pushed.

| Check | Result |
|---|---|
| clang-format (`test/initramfs/src/regression/.clang-format`) | PASS |
| `./tools/format_all.sh --check` | PASS |
| `./tools/clippy_check.sh workspace` x86_64 | PASS (with `CARGO_BUILD_JOBS=4`; two earlier attempts died of `posix_spawn: EAGAIN` because the user slice sits at ~8028/8192 tasks) |
| new test on Linux 7.1.9 (host, `/tmp` on ext4; `/ext2`, `/exfat` absent) | 7/7 checks passed |
| `make run_kernel AUTO_TEST=regression` on the fix (network suite and the `nvme` test skipped, see below) | all suites passed, fs suite includes `read_eof` on all three file systems |
| same, kernel change stashed, test kept (unpatched `51c59734e`) | only `read_eof` fails: 2 failing checks per test function (`/tmp`, `/exfat`), every other suite passes |
| pristine `604948581`, same test binary | same 6 failing checks (`logs/ast05-fix-read_eof-baseline-604948581.txt`) |

Skipped suites: `network` because `test_tcp_read_wrap_receive_buffer_tail`
fails intermittently on unpatched main (2/46 checks, timing dependent); the
`device/nvme` test because `mount('/dev/nvme0n1')` returns `EINVAL` on
unpatched main in this environment (QEMU 10.2.1). Both reproduced on the
baseline before the fix was applied.

Environment note: the host's `user-1000.slice` has `pids.max=8192` and sat at
~8028 during this work (long-lived `gitstatusd`, `codex-raw app-server` and
`claude` processes from other sessions). Builds only succeed with
`CARGO_BUILD_JOBS=4` and `NIX_CONFIG='max-jobs = 1\ncores = 4'`.

## AST-09 fix validation (branch `fix/vectored-io-restart`, base `e60087be1`)

Scratch worktree `aster-ast05` (reused for its warm build), branch created
2026-09-02 from `upstream/main` `e60087be1`. Commits: `10b2439cd` (map
`EINTR` to `ERESTARTSYS` in `do_sys_readv`/`do_sys_writev`, zero-progress
arm only) and `f80ee60c2` (regression test
`process/signal/vectored_io_restart`, three cases). Nothing pushed. PR text:
`../asterinas-bug-findings-2026-08/upstream-issues/AST-09-pr-draft.md`; patches:
`AST-09-patches/`. Script: `scripts/ast09-validate.sh`; logs: `logs/ast09/`.

| Step | Result |
|---|---|
| `./tools/format_all.sh --check` | PASS |
| `./tools/clippy_check.sh workspace` (x86_64) | PASS |
| Run A: fixed tree, full regression (network suite and nvme test skipped, pre-existing failures on main) | all suites pass; `vectored_io_restart` 22/22 checks pass (`logs/ast09/regression-fix.log`) |
| Run B: `preadv.rs`/`pwritev.rs` from `upstream/main`, process suite only | only `readv_on_empty_pipe_restarts` and `writev_on_full_pipe_restarts` fail (`readv`/`writev` got `EINTR`, expected success); `readv_on_empty_pipe_fails_without_sa_restart` passes (`logs/ast09/regression-nofix.log`) |
| Linux 7.1.9 control (host gcc, same source) | 22/22 pass, 6.0 s (`logs/linux-7.1.9-ast09-vectored_io_restart.txt`) |

Notes: the guest run of the new test also takes ~6 s (three `sleep(1)` pairs).
Commit trailers are `Signed-off-by` only, matching the AST-05 commits the user
filed; no session trailer was added.

## AST-09 via #3576 (branch `scratch/3576-on-main`, base `d76b4dcc0`)

PR #3576 (StevenJiang1110, opened 2026-07-10, last push 2026-07-23, no human
review as of 2026-09-03) makes the `pause` family return `ERESTARTSYS` and
drops the per-syscall `EINTR` mapping. It never touches `preadv.rs` or
`pwritev.rs`; the vectored calls are fixed as a side effect. Its
`syscall_restart.c` has no readv/writev case. Decision 2026-09-03: file an
issue that references #3576 and offer the two cases as a patch to that PR;
`AST-09-pr-draft.md` is held as the fallback. Issue text:
`../asterinas-bug-findings-2026-08/upstream-issues/AST-09-issue-draft.md`.

Branch in scratch worktree `aster-ast05`: `upstream/main` `d76b4dcc0` +
merge of `pr-3576` head `8e02d0e94` (`d2e4ed4b9`; one conflict in
`pause.rs`, resolved as the PR's doc line over main's `pub(crate) trait
Pause`) + `a57ded014` (readv/writev cases added to `syscall_restart.c`).
Patch: `AST-09-patches/for-pr-3576/0001-*.patch`, `git apply --check` passes
against `8e02d0e94`. Scripts: `scripts/ast09-3576-validate.sh`,
`scripts/ast09-3576-unpatched.sh`; logs: `logs/ast09-3576/`.

| Step | Result |
|---|---|
| `./tools/format_all.sh --check` on the merged tree | PASS |
| `./tools/clippy_check.sh workspace` (x86_64) on the merged tree | PASS |
| Run C: main + #3576 + the two cases, process suite only | all pass; `syscall_restart` 8/8 cases, 55/55 checks (`logs/ast09-3576/regression-3576.log`) |
| Run D: unpatched main `d76b4dcc0` + the same `syscall_restart.c` + `repro-min.c`, process suite only | `repro-min`: `read`/`write` restarted, `readv`/`writev` `ret=-1 errno=4`; `syscall_restart`: `readv_restarts_with_sa_restart` and `writev_restarts_with_sa_restart` fail (`got Interrupted system call, but expected Success`), plus #3576's own `socket_read_with_timeout_does_not_restart` (`got Success, but expected Interrupted system call`); `futex_wait_with_timeout_does_not_restart` already passes on main (`logs/ast09-3576/regression-main-unpatched.log`) |
| Linux 7.1.12 control, merged `syscall_restart.c` (host gcc) | 8/8 cases pass (`logs/linux-7.1.12-3576-syscall_restart.txt`) |
| Linux 7.1.12 control, `repro-min.c` | all four calls restarted (`logs/linux-7.1.12-ast09-repro-min.txt`) |

## AST-05 review round 1 (branch `scratch/3778-review`, base PR head `3aa75efd3`)

Reviewer (cchanging, 2026-09-03) asked for (1) taking the `page_cache` lock
before reading the size in ramfs `read_at` to avoid racing `resize`, and
(2) `writer.limit` in place instead of `clone_exclusive` + `skip`. Both
applied as `0adae3fb1` on `scratch/3778-review` in the `aster-ast05`
worktree (ramfs: lock first, in-place limit; exfat: in-place limit). Patch:
`../asterinas-bug-findings-2026-08/upstream-issues/AST-05-patches/review/0001-*.patch`.
Stress: `minimal/truncate_read_race.c` (churn thread `ftruncate(0)` +
`pwrite(8 KiB)`; reader fills 0xAA, `pread(8 KiB)`, counts reads whose
`[0, ret)` still holds 0xAA). Script: `scripts/ast05-review-validate.sh`;
logs: `logs/ast05-review/`.

| Step | Result |
|---|---|
| Run G: PR base `e60087be1` (no AST-05 change), fs suite + stress on `/tmp` (ramfs) | fs suite passes; stress `anomalies=7396` of 200000 (`logs/ast05-review/regression-prbase.log`) |
| Run E: PR head `3aa75efd3`, fs suite + stress on `/tmp` (ramfs) | fs suite passes; stress `anomalies=8357` of 200000 (`ret=8192, first unwritten byte at 0`) (`logs/ast05-review/regression-prhead.log`) |
| Run H: PR head `3aa75efd3`, same, but `SMP=1` (the CI `handover64-debug` variant's CPU count) | stress `anomalies=0` of 200000: a single CPU does not hit the race (`logs/ast05-review/regression-prhead-smp1.log`) |
| Run I: PR head kernel + `fs/read_truncate_race` (commit `bdecccdf7`, regression form of the stress, 20000 rounds), fs suite, `SMP=2` | `count_unwritten_reads()` fails, fs suite reports failure (`logs/ast05-review/regression-test-prhead.log`) |
| Run J: `bdecccdf7` (lock reorder + the test), fs suite, `SMP=4` (CI `multiboot2-smp4`) | fs suite passes, `read_never_reports_unwritten_bytes` 3/3 (`logs/ast05-review/regression-test-review-smp4.log`) |
| Linux 7.1.12 host, `read_truncate_race.c` built against `common/test.h` | 3/3; `strace -c` shows 20002 `pread64` and 9277 `ftruncate`/`pwrite64` pairs (`logs/linux-7.1.12-ast05-read_truncate_race.txt`) |

The regression test lives on `scratch/3778-review` as `bdecccdf7` (after
`0adae3fb1`); `clang-format --dry-run -Werror` passes. Decision 2026-09-03
(user): add it to the PR; it detects the regression only on SMP runs, which
the commit message says.
| `./tools/format_all.sh --check`, `./tools/clippy_check.sh workspace` (x86_64) on `0adae3fb1` | PASS, PASS |
| Run F: `0adae3fb1`, full regression (network suite, nvme skipped) + stress | all suites pass; `read_eof` 21/21; stress `anomalies=0` of 200000 (`logs/ast05-review/regression-review.log`) |
| Linux 7.1.12 control, stress on `/dev/shm` | `anomalies=0` of 200000, `short=199634` (`logs/linux-7.1.12-truncate_read_race.txt`) |

Reading: the anomaly is a pre-existing count bug (the copy is clamped by
`Vmo::read`, the length is not), reachable during any truncate or extending
write; the lock reorder removes it. The in-place limit changes no result;
`readv` at EOF now breaks one iteration later after a zero-length `read_at`
(same as ext2 today).

## Both AST-05 branches on `upstream/main` (branch `scratch/3778-stack-on-main`, base `864b9138b`, 2026-09-04)

Question: can `scratch/3778-review` and `fix/exfat-write-size-race` be based
on `main` instead of the PR #3778 head? `upstream/main` moved from
`e60087be1` to `864b9138b`; the two new commits there rework the symlink
implementation and touch both `ramfs/fs.rs` and `exfat/inode.rs`. Cherry-pick
trials in a temporary worktree (`scripts/ast05-stack-on-main.sh`, logs in
`logs/ast05-review/`):

| Trial | Result |
|---|---|
| main + PR #3778 (`b13b3252b`, `3aa75efd3`) + review fixes (`0adae3fb1`, `bdecccdf7`) | clean |
| main + exfat write fix alone (`d5b645d84`, `97199dd30`), without PR #3778 | clean |
| main + all six | clean, kept as `scratch/3778-stack-on-main` (`9323be332..4b39370e8`) |
| main + review fixes alone, without PR #3778 | conflicts in both files: they edit the `read_at` that PR #3778 rewrote |

On the six-commit stack: `format_all.sh --check` passes; fs regression suite
with `SMP=4` passes, 184 test summaries with 0 failures, including
`read_eof` (21/21), `read_never_reports_unwritten_bytes` (3/3) and
`concurrent_extending_writes_fill_the_file` (3/3)
(`logs/ast05-review/regression-stack-on-main.log`). Other suites and clippy
were not rerun on the stack.

So: the exfat write fix can go up as its own PR on `main`; the review fixes
stay tied to PR #3778 (squash into it or append to its branch). This trial
did not rewrite any branch. Later the same day `fix/ramfs-read-past-eof` was
rewritten as four commits (`106c89481..4559cc403`, review fixes folded in,
still on the PR base `e60087be1`) and `scratch/3778-review` and
`scratch/3778-stack-on-main` were deleted; see
`upstream-issues/AST-05-pr-draft.md`, "Rewritten for push", and
`references/pr-3778-handoff.md`.

Harness note: a `cargo-osdk` built with a plain `cargo build` generates a
run crate that pulls `ostd` from crates.io next to the in-tree one and fails
with "the `#[global_allocator]` in ostd conflicts with global allocator in:
ostd". Build it with `OSDK_LOCAL_DEV=1`, as `make install_osdk` does, and
do not seed `target/` from another worktree.

## AST-05 review round 1, second look: in-place `limit` breaks readv (2026-09-07)

Question: is the four-commit rewrite (`4559cc403`, in-place
`writer.limit(read_len)` as the reviewer suggested) safe? A source-level
counterexample from a separate review said no. `do_sys_preadv` and
`do_sys_readv` (`kernel/core/src/syscall/preadv.rs:121`, `:170`) decide
whether to move on to the next iovec by `writer.has_avail()` after the file
system returns. Limiting the caller's writer in place makes that false after
any short read, so the loop continues; a write that lands between the two
per-iovec `read_at` calls is then counted with its bytes in `iov[1]` while
`iov[0]` keeps an unfilled tail. readv(2) requires `iov[0]` to be full
before `iov[1]` is touched. `Vmo::read` advances the writer through
`read_fallible` (`vm/page_cache/vmo/mod.rs:557`), so after a limited copy
`avail()` is 0 whatever the iovec size was.

Guest check with a new regression test, `fs/readv_append_race`: a 2-byte
ramfs file, `preadv` with an 8192-byte and a 1-byte iovec, both
sentinel-filled, a second thread alternating a 1-byte append and a truncate
back to 2 bytes, 20000 rounds. A violation is a sentinel inside the counted
range of `iov[0]` or any byte in `iov[1]`. Scratch branch
`scratch/readv-race` in the `rebase-try` worktree; scripts
`scripts/readv-run.sh`, `scripts/readv-B.sh`, `scripts/restore-clone.py`;
logs `logs/ast05-review/readv-{A,B}.{log,out}`; patches
`upstream-issues/AST-05-patches/readv/`.

| Run | Tree | `SMP` | `readv_append_race` | fs suite |
|---|---|---|---|---|
| A | `4559cc403` + test (`a06b55282`), in-place `limit` | 4 | 294/20000 reads split across the iovecs, fails | stops at the failure |
| B | A + `clone_exclusive()`+`limit()`+`skip()` restored in ramfs and exfat (`379902e88`) | 4 | 0/20000, passes | 184 test summaries, 0 failures |
| C | A + hardened loops only (`898bf2076`, in-place `limit` kept): `do_sys_preadv`/`do_sys_readv` break when `read_len < avail` captured before the call, never look at the writer afterwards | 4 | 0/20000, passes | 184 test summaries, 0 failures; `format_all.sh --check` passes |
| Linux 7.2.3 host, same `.c` | | 24 CPUs | 0/20000 in four runs | |

Runs B and C both recompiled `aster-core` and `asterinas` (logs), so each
ran its own kernel. Run C (branch `scratch/readv-loop`, patch
`upstream-issues/AST-05-patches/readv-loop/`, script `scripts/harden-loop.py`)
shows the loop's dependence on the writer's state after the call is the
defect: fixing the loop alone is enough, and it would also cover ext2. That
is a syscall-layer change for a separate PR; for PR #3778 the clone form
(run B) is the in-scope fix. The reviewer's second suggestion therefore cannot be taken as is:
the clone is not there to protect later writes through the writer, it keeps
the caller's view of the remaining space intact. Both file systems in the PR
are affected; the published PR head `3aa75efd3` (clone form) is not. ext2
(`ext2/inode/file.rs:239-241`, `:281-282`, upstream code) limits in place
today and has the same latent problem; it is outside this PR.

Two more findings from the same review, both in `read_truncate_race.c`:
`static volatile int stop` shared between threads is a C11 data race (use
`_Atomic int`, as `device/pty/pty_blocking.c` does), and
`TEST_RES(pthread_create(...))` does not stop the test on failure, so a
failed create is followed by a join on an uninitialised handle (use
`CHECK_WITH`). The new test uses both forms already.

v3 series (2026-09-07, on the user's instruction): `fix/ramfs-read-past-eof`
rewritten as five commits on `e60087be1`: `c07396aa9` clone-form limit
(the PR's original change, message explains the clone), `f43ce76f9`
`read_eof`, `7b5d15b1a` lock order, `b9ba463df` `read_truncate_race` with
`_Atomic int` and `CHECK_WITH`, `aa3e5a12d` `readv_append_race`. Kernel
tree identical to run B. `format_all.sh --check` passes; fs suite with
SMP=4: 184 test summaries, 0 failures, `readv_append_race` 0/20000
(`logs/ast05-review/readv-V3.{log,out}`, `scripts/v3-build.sh`,
`scripts/fix-race-test.py`). Patches: `upstream-issues/AST-05-patches/v3/`.
The v2 head is kept as `scratch/3778-v2`. Not pushed.

v4 series (2026-09-08): v3 rebased onto `upstream/main` `1601bf537` with
the readv test moved after `read_eof`: `955efe1c3` clone-form limit,
`d77bfb8f4` `read_eof`, `9da731a30` `readv_append_race`, `2e355d3ef` lock
order, `9b1fb34a8` `read_truncate_race` (commit 4's message was reworded
the same day, which re-parented commit 5: `b4e96d67b`, `c30e6eb4a`; both
trees unchanged). Test files and registration are identical to v3
(`scripts/v4-build.sh` printed a non-empty "test tree vs v3" stat because
it diffed all of `test/` across the base move; scoped to the three test
directories plus `fs/Makefile` and `fs/run_test.sh` the diff is empty);
kernel diff against `main` is the two `read_at` functions.
Commit 1 builds alone on `1601bf537` (`logs/ast05-review/v4-c1-build.tail`);
`format_all.sh --check` passes; fs suite with SMP=4 on the tip: 184 test
summaries, 0 failures, `readv_append_race` 0/20000
(`logs/ast05-review/readv-V4.{log,out}`, `scripts/v4-build.sh`,
`scripts/v4-run.sh`, `scripts/register-test.py`). Patches:
`upstream-issues/AST-05-patches/v4/`. Two harness stops on the way: the
`smoltcp` git tag bump on `main` needs its ref added to cargo's git db for
offline builds, and one QEMU host-port collision with another guest (rerun).
Not pushed.

v4 review (2026-09-08, by hand after the `/code-review` agent hit a rate
limit; record in `references/pr-3778-handoff.md`): no blocking finding.
Commit 4's message blamed a cache "shrink or grow" for the wrong count;
only a shrink clamps the copy, so it was reworded (`2e355d3ef` ->
`b4e96d67b`, `9b1fb34a8` -> `c30e6eb4a`, all five trees unchanged, so the
validation above stands; patches 0004 and 0005 regenerated). Commit 3's
claim that `readv_append_race` passes on the unpatched tree was inferred
from `PageCache::resize` rounding to `PAGE_SIZE`; measured now:

| Run | Tree | `SMP` | `readv_append_race` | fs suite |
|---|---|---|---|---|
| BASE | `1601bf537` + `d77bfb8f4` + `9da731a30`, `read_eof` dropped from `run_test.sh` (it fails without the fix and the script has `set -e`); `scratch/readv-base` `8b406c247` | 4 | 0/20000, passes | passes (`logs/ast05-review/readv-BASE.{log,out}`, `scripts/base-run.sh`) |

Second review (2026-09-08, `/code-review xhigh`; findings and
dispositions in `references/pr-3778-handoff.md`, "Second review"): the
series itself clean; commit 5's message reworded (`89b3b6149` ->
`690a8651f`, tree unchanged: its "about 4%" figure is the 200000-round
stress loop's, `regression-prbase.log:202` and `regression-prhead.log:203`,
not the test's); the "185 summaries" figures above corrected to 184
`test_* summary:` lines (the 185th `summary:` line is exfat's `Media
summary`); the v4 harness scripts replaced by `scripts/series-run.sh`.
Before the review the user's `git pull upstream main` (16:18,
`pull.rebase=true`) had moved the branch onto `4d395b885`; `git
range-diff` shows all five patches unchanged, new ids `aed0b0a15`,
`6a525636c`, `e949b611c`, `58ccd4470`, `690a8651f`. Validation repeated
on that base:

| Run | Tree | `SMP` | `readv_append_race` | fs suite |
|---|---|---|---|---|
| V4B | `690a8651f` on `4d395b885` (`scripts/series-run.sh V4B`) | 4 | 0/20000, passes | commit 1 alone builds (`logs/ast05-review/v4b-c1-build.tail`); `format_all.sh --check` passes; 184 test summaries, 0 failures, `read_eof` 6/6 and 9/9, `read_truncate_race` passes (`logs/ast05-review/readv-V4B.{log,out}`) |

`upstream/main` has since added 15 AArch64 commits
(`c051d0ada..819d6628c`); of the series' files they touch only a `cfg`
list in `ostd/src/mm/io/mod.rs`. The branch stays on `4d395b885`. Not
pushed.
