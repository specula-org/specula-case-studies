# AST-08: IOMMU teardown frees frames before IOTLB invalidation

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | External package, finding CR-20 (former catalog alias OS-02), original run ID not recorded, Asterinas pin `4c1fdd1e4`, verified 2026-08-06 |
| Also seen in | none. Later ktest re-runs (a local reproduction on 2026-08-07, `604948581` and `29b0f4bcf` on 2026-09-02) are validations, not separate Specula runs. |
| Syscalls | none (device DMA path) |
| Upstream | No direct match. Reviewed and rejected: open issue [#237](https://github.com/asterinas/asterinas/issues/237) (generic IOMMU protection), merged PRs [#2351](https://github.com/asterinas/asterinas/pull/2351) and [#3108](https://github.com/asterinas/asterinas/pull/3108) (carry the FIXME), merged PR [#1218](https://github.com/asterinas/asterinas/pull/1218) (interrupt-cache invalidation only), closed issue [#2849](https://github.com/asterinas/asterinas/issues/2849) (CPU TLB in `KVirtArea`). |
| Fix | Local branch `fix/iommu-iotlb-invalidate` in `/home/chin39/Documents/asterinas-dev` (`d370078dd`, `9f338d737`, `bfef1ca11` on `29b0f4bcf`), validated with the vIOMMU A/B on 2026-09-02. Not pushed. The PR draft is not filed. |
| Reproducer | repro/ (ostd ktest with QEMU vIOMMU and `edu` device, runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

On x86_64 with Intel VT-d DMA remapping, dropping a `DmaCoherent` or
`DmaStream` removes the IOMMU page-table entries and returns the frames to the
frame allocator without invalidating the IOTLB. A device that cached the
translation can keep writing through the revoked device address into a frame
that now belongs to an unrelated kernel allocation. Nothing ever invalidates
the entry, so the window stays open for the life of the VM. The attacker is a
DMA-capable device, or a vIOMMU cache. An unprivileged process cannot drive
it.

## Linux contract

Not a syscall contract. The expected property is DMA revocation: once an
unmap returns and the frames are freed, the device must not reach them. VT-d
requires IOTLB invalidation after a translation is removed, and Linux performs
it, either synchronously or through a deferred flush queue whose window is
bounded. The verification package (§7.4) cites the DATE 2024 paper "IOMMU
Deferred Invalidation Vulnerability: Exploit and Defense" and Thunderclap
(NDSS 2019) as prior art for this class. Asterinas omits the invalidation
entirely.

## Asterinas behavior

Line numbers are at `4c1fdd1e4` and were rechecked as unchanged at `604948581`
(2026-08-25) and on main `29b0f4bcf` (2026-09-02).

- `ostd/src/mm/dma/util.rs::unmap_dma_remap` (lines 299-314) calls
  `iommu::unmap(da)` per page and carries only
  `// FIXME: Flush IOTLBs to prevent any future DMA access to the frames.` A
  TODO above the loop leaks the device address range on purpose, because
  reusing it without flushes would corrupt data.
- `ostd/src/mm/dma/util.rs::unprepare_dma` (lines 175-183) calls
  `unmap_dma_remap` and then does only TDX bookkeeping.
- `ostd/src/mm/dma/dma_coherent.rs::<DmaCoherent as Drop>::drop` (lines
  139-144) and `ostd/src/mm/dma/dma_stream.rs::<DmaStream as Drop>::drop`
  (line 358) call `unprepare_dma` and then free the frames unconditionally.
- `ostd/src/arch/x86/iommu/dma_remapping/mod.rs::unmap` (lines 106-122) only
  runs a page-table cursor. `ostd/src/arch/x86/iommu/invalidate/descriptor/mod.rs`
  defines only the interrupt-entry-cache and wait descriptors, with no IOTLB
  invalidate descriptor.

The fix work found a second, latent bug that the fix would expose:
`ostd/src/arch/x86/iommu/invalidate/queue.rs::Queue::append_descriptor`
wrapped the tail only on the next append, so after the 256th descriptor the
Invalidation Queue Tail register rejected the write and the completion wait
spun forever.

## Reproduction

There is no userspace reproducer. The reproducer is an `ostd` ktest that
drives QEMU's `edu` PCI device through the IOMMU in three phases: DMA through a
live mapping, drop the mapping and reclaim the same frame as an ordinary
allocation filled with a witness pattern, then have the device write to the
revoked address. A control write to a never-mapped address must fault. See
`repro/README.md`.

| Run | Result |
|---|---|
| `4c1fdd1e4`, original package, QEMU 11.0.2 | `witness_intact_after_control=true`, `witness_clobbered_after_replay=true`. vIOMMU trace: 1 IOTLB fill, 2 hits, 0 flushes, 16 DMAR faults (all from the control). `vtd_iotlb_page_hit ... iova 0x3fffffe000 slpte 0x13206083` after teardown. |
| `49ebefd67` (local Nix branch, 2026-08-07), QEMU 10.2.1 | fills=1, hits=2, flushes=0, faults=16 |
| `604948581`, 2026-09-02, QEMU 10.2.1, TCG, SMP=2 | REPRODUCED, both conditions true, 0 invalidations over boot and test |
| `29b0f4bcf` (main), 2026-09-02, fix baseline | FAILED with `witness_clobbered_after_replay=true`, 0 invalidations |
| `29b0f4bcf` plus fix branch | ok, `witness_clobbered_after_replay=false`, one `vtd_inv_desc_iotlb_pages`, and the replay write faults like the control |

A FAILED ktest is the positive result.

## Fix and upstream status

- Upstream dedup (2026-09-14): `NO_DIRECT_MATCH`. The only in-tree record is
  the FIXME comment, introduced by `71681dd94` (PR #2351).
- Local fix, branch `fix/iommu-iotlb-invalidate` (read-only check on
  2026-09-24: 3 commits on `29b0f4bcf`, 148 commits behind upstream, no remote
  branch):
  1. `d370078dd` "Wrap the invalidation queue tail before it reaches the queue size".
  2. `9f338d737` "Invalidate the IOTLB when unmapping DMA addresses". This adds
     an IOTLB Invalidate descriptor and submits one page-selective or
     domain-selective invalidation per range, waiting for completion before
     `unmap_dma_remap` returns. It also adds a register-based fallback and the
     ktest `dma_teardown::survives_invalidation_queue_wrap` (1024 teardowns).
  3. `bfef1ca11` "Free device address ranges after unmapping DMA".
- Validation of the final branch (2026-09-02): format and clippy passed for
  x86_64, riscv64, and loongarch64. The CR-20 ktest passed. `ostd` ktests: 204
  passed on plain QEMU, and 204 passed under `-device intel-iommu` with 1039
  page-selective invalidations and 0 DMAR faults. `make run_kernel
  SCHEME=iommu AUTO_TEST=regression`: all suites passed with the network suite
  and the NVMe test skipped. Both of those fail on unpatched main in that
  environment.
- Patches:
  `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/upstream-issues/AST-08-patches/`.
  PR draft (not filed):
  `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/upstream-issues/AST-08-pr-draft.md`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-08-iommu-stale-iotlb/description.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-08-iommu-stale-iotlb/verification-package-local-copy.md` (identical to `/home/chin39/Documents/play/specula-profile/reports/CR-20-verification-report.md`)
- `/home/chin39/Documents/play/specula-profile/reports/cr20/` (`HANDOFF.md`, `REPRODUCE.md`, `run.sh`, `run.log`)
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md` ("AST-08 detail" and "AST-08 fix validation")
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/ast08-driver-summary.txt`, `ast08-ktest-cr20_stale_iotlb_after_dma_teardown.txt`, `ast08-fix-*.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/ast08-codex-handoff-slice1.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/upstream-issues/AST-08-pr-draft.md` and `AST-08-patches/`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-08`)

## Caveats

- Device attacker model. The evidence is a QEMU vIOMMU with the synthetic
  `edu` device, not physical VT-d hardware. The observed stale entry is in the
  vIOMMU's own IOTLB (`vtd_iotlb_page_hit`).
- x86_64 Intel VT-d only. RISC-V and LoongArch stub out `unmap`.
- `-m 8G` is a harness requirement. The IOMMU registers near `0xfed90000` are
  reached through the linear map, and with the default 2G the kernel faults in
  `iommu::init`.
- The tree has no ATS support, so device-side IOTLB invalidation is not
  covered by the local fix and would be needed once ATS is enabled.
- `4c1fdd1e4` is not an upstream commit. It is the head of a local
  `feat/nix-flake-devenv` branch in `/home/chin39/Documents/asterinas` (8 Nix
  packaging commits on upstream `9388d7d47`). The 2026-08-07 local reproduction
  ran on `49ebefd67`, the same 8 commits rebased onto upstream `a110dfc73`.
  Neither branch touches `ostd`.
- Under `SCHEME=iommu`, unpatched main already fails the NVMe ext2 mount
  (`EINVAL`) and intermittently fails `test_tcp_read_wrap_receive_buffer_tail`
  in that environment. These failures are not caused by the fix.
