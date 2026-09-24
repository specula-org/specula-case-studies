# AST-08 reproducer (ostd ktest with vIOMMU and the QEMU edu device)

AST-08 needs a DMA-capable device, so there is no userspace reproducer. The
reproducer is an `ostd` ktest that programs QEMU's `edu` PCI device through
the public DMA API. It does not modify `ostd` logic.

## Files and where they came from

| File | Source | Notes |
|---|---|---|
| `verification-package.md` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-08-iommu-stale-iotlb/verification-package-local-copy.md` (identical to `/home/chin39/Documents/play/specula-profile/reports/CR-20-verification-report.md`) | The external CR-20 package: claim, expected output, falsification criteria, fix direction. Its §6 driver does not run unmodified on current trees (see below). |
| `test_bugCR-20_stale_iotlb_after_teardown.rs` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/harness/cr20_repro.rs` | Byte-identical to the §5 listing. This is the ktest module. |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/cr20/run.sh` | The driver used for the 2026-08-07 local reproduction. It fixes three problems in the §6 driver, described in `/home/chin39/Documents/play/specula-profile/reports/cr20/HANDOFF.md` §3. |
| `OSDK.cr20.toml` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/OSDK.cr20.toml` | The `ostd/OSDK.toml` used on 2026-09-02. Same QEMU arguments that `run.sh` writes. |
| `run-cr20-validation-2026-09-02.sh` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/run-cr20.sh` | The exact commands run on 2026-09-02. **Environment-specific:** it expects `$SCRATCH/aster-pin`, `$SCRATCH/OSDK.cr20.toml`, and `$SCRATCH/harness/cr20_repro.rs`, and its default `SCRATCH` is a session directory that no longer exists. |

The three `run.sh` fixes relative to the package's §6 driver: it creates and
later deletes `ostd/OSDK.toml` instead of backing up a file that does not exist
in these trees, it appends the module registration when the §6 anchor
(`mod tla_scenarios;`) is missing, and it defaults the worktree to its parent
directory. Always pass the worktree path explicitly.

## Host prerequisites

- x86_64 host. An AMD host is fine, because the vIOMMU is a QEMU device model.
- QEMU with the `edu` and `intel-iommu` devices
  (`qemu-system-x86_64 -device help | grep -E 'edu|intel-iommu'`) and the
  `vtd_*` trace events (`qemu-system-x86_64 -trace help | grep vtd_iotlb`). The
  recorded runs used QEMU 11.0.2 (original) and 10.2.1 (local, from the
  Asterinas Nix dev shell).
- 8 GiB of guest RAM. `-m 8G` is required: the IOMMU registers near
  `0xfed90000` are reached through the linear map, and with 2G the kernel
  faults in `iommu::init`.
- The Asterinas toolchain (`nix develop` in the checkout, or the
  `asterinas/dev` Docker image). `run.sh` uses `nix develop` only when the
  checkout has a `flake.nix`, otherwise it runs the commands directly.

## Where the files go in an Asterinas tree

1. `test_bugCR-20_stale_iotlb_after_teardown.rs` becomes
   `ostd/src/cr20_repro.rs`.
2. `ostd/src/lib.rs` gets `#[cfg(ktest)] pub(crate) mod cr20_repro;` (the
   2026-09-02 run inserted it just before `#[cfg(ktest)] mod test {`).
3. `ostd/OSDK.toml` holds the contents of `OSDK.cr20.toml`: `qemu-direct` boot,
   `-device intel-iommu,intremap=on,device-iotlb=on`,
   `-device edu,dma_mask=0xffffffffff`, and the `vtd_*` trace events. OSDK
   reads the manifest from the current directory first, so this file fully
   overrides the root `OSDK.toml` while tests run from `ostd/`. None of
   `604948581`, `29b0f4bcf`, or `bc12195df` has an `ostd/OSDK.toml`.

`run.sh` does all three steps. It removes `ostd/OSDK.toml` on exit and leaves
the module and its registration in place.

## Build and run

```sh
cp test_bugCR-20_stale_iotlb_after_teardown.rs run.sh /some/dir/ && cd /some/dir
SMP=2 ./run.sh /path/to/asterinas
```

`run.sh` builds `osdk/target/debug/cargo-osdk` from the worktree with
`OSDK_LOCAL_DEV=1` if it is missing, then runs
`cargo-osdk osdk test cr20_repro::cr20_stale_iotlb_after_dma_teardown --target-arch x86_64`
from `ostd/`. It writes the full log to `run.log` next to itself. Overrides:
`OSDK_BIN`, `BUILD_TIMEOUT_SECONDS` (2400), `TEST_TIMEOUT_SECONDS` (3000), and
`SMP` (2). Delete a stale `osdk/target/debug/cargo-osdk` if the worktree has
moved, because an old binary keeps testing the tree it was built from.

To test a fix, run the same script on the fixed worktree. A passing ktest with
`witness_clobbered_after_replay=false` and a nonzero `IOTLB flushes` count is
the fixed result.

## Reading the output

**A FAILED ktest is the positive result.** The harness asserts that the bug
is absent.

| Output | Bug present | Bug absent (fixed) |
|---|---|---|
| `test result:` | `FAILED. 0 passed; 1 failed` | `ok. 1 passed` |
| `CR20\| SUMMARY` | `witness_intact_after_control=true witness_clobbered_after_replay=true` | `witness_intact_after_control=true witness_clobbered_after_replay=false` |
| `IOTLB flushes` (host trace count) | 0 | at least 1 (`vtd_inv_desc_iotlb_pages`) |
| `vtd_iotlb_page_hit ... iova <revoked daddr>` after phase 2 | present | absent; the replay write raises DMAR faults like the control |
| `DMAR faults` | 16, all from the control write | 32 (16 control plus 16 replay), recorded with the invalidation commit applied |

Both conditions must hold for a valid positive:
`witness_intact_after_control=true` proves the IOMMU is enforcing, and
`witness_clobbered_after_replay=true` shows the stale entry was used. The run
proves nothing if the control is clobbered, if the frame did not come back
from the allocator (`ENV: frame ... did not come back`), or if the guest
prints an `ENV:` line about missing DMA remapping or a missing `edu` device.
The full list is in `verification-package.md` §9.

`SMP=2` matches every recorded run. The bug is not a concurrency bug.
