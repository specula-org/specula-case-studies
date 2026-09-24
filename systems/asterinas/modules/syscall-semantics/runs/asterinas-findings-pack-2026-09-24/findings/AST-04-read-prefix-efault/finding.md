# AST-04: A copied read prefix is erased by EFAULT reporting

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-1 (former catalog alias RF-04), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | GLM `asterinas-glm53-eval-20260826T035049Z` MC-1, REPRODUCED (mapped to both AST-01 and AST-04). Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z` analysis-report T-1/CR-1 and modeling-brief T-1/CR-1, analysis-only candidates. |
| Syscalls | `read`, `pread64`, `readv`, `preadv` |
| Upstream | Direct match: open issue [#711](https://github.com/asterinas/asterinas/issues/711) ("Wrong behavior when `EFAULT` occurs in the middle of I/O system calls"). Open PR [#3729](https://github.com/asterinas/asterinas/pull/3729) leaves mid-copy short-read handling for future work. |
| Fix | Upstream: none, #711 is open. Local only: the historical 01a v5 `fixes.patch` (A/B validated at the pin), not rebased and not submitted. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

A `read()` or `pread64()` into a buffer whose tail faults after a writable
prefix copies the prefix into the user buffer, then returns `-1`/`EFAULT` and
leaves the shared offset where it was. The next read on the same open file
description delivers the same bytes again, so a caller that repairs its
mapping and retries, or another holder of a `dup`ed descriptor, sees those
bytes twice. Linux returns a short read of the delivered prefix.

## Linux contract

read(2): "On success, the number of bytes read is returned (zero indicates end
of file), and the file position is advanced by this number. It is not an error
if this number is smaller than the number of bytes requested." On Linux 7.1.9
(2026-09-02) the reproducer's read returned 128 with the offset at 128, and the
next read started at the following byte (`'Y'`). The zero-prefix control (the
first byte faults) returns `EFAULT` on both kernels, which isolates "EFAULT
after a positive prefix" from "EFAULT is wrong".

## Asterinas behavior

At pin `604948581`:

- `ostd/src/mm/io/mod.rs::VmReader::read_fallible` (lines 332-362) copies the
  prefix, advances the writer cursor, and returns `(PageFault, copied)`.
- `kernel/core/src/error.rs::From<(ostd::Error, usize)>::from` (lines 209-219)
  drops `copied`.
- `kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::read` (lines 534-566)
  propagates the error with `?` after the copy has already happened.
- `kernel/core/src/fs/file/inode_handle.rs::InodeHandle::read` (the `FileLike`
  impl, lines 285-290) advances the offset only on `Ok`.

## Reproduction

`repro/repro.c` (01a MC-1, byte-identical to the run's
`test_bugMC-1_partial_read_efault.c`) maps a page, makes everything after a
128-byte prefix `PROT_NONE`, and reads an 8192-byte file into it. With no
arguments it tests `/mc1-regular-file` (ramfs) and `/ext2/mc1-regular-file`.
With arguments it tests each given path. It prints `MC1_ANOMALIES <n>` and
`MC1_RESULT MATCHES_LINUX` or `MC1_RESULT DIVERGES_FROM_LINUX`.

Recorded on 2026-09-02 at the pin (SMP=2): `read` returned `-1`/`EFAULT` with
128 bytes already in the buffer and the offset at 0, and the next read replayed
`'A'`. Six anomalies in total across ramfs and ext2, `DIVERGES_FROM_LINUX`.

`repro/variants/GLM-MC-1/` covers the same mechanism through `readv` with a
later faulting iovec.

## Fix and upstream status

- Upstream dedup (2026-09-14): `EXACT_MATCH`. #711 directly reproduces a
  delivered prefix returned as `EFAULT` with the next read repeating data. It
  was maintainer-confirmed as still present on 2026-07-14 and was open on
  2026-09-24. Do not file this as a new issue.
- What these runs add beyond #711's PoC: #711 checks only the return value,
  while this reproducer measures the offset and re-delivery consequences
  through the shared open file description.
- Local fix in the 01a v5 `fixes.patch`: the VMO read loop turns a fault after
  a positive prefix into `Ok(())` with the cursor carrying the progress, and
  ext2/ramfs derive the return value from the writer cursor. A/B at the pin:
  `DIVERGES_FROM_LINUX` before, `MATCHES_LINUX` with 0 anomalies after. Patch
  path:
  `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z.fixes.patch`.
- `vmo/mod.rs` and `error.rs` were byte-identical on main `29b0f4bcf`
  (2026-09-02, static check). The only change in `ostd/src/mm/io/mod.rs` was a
  `debug_assert!` in `from_user_space`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-04-read-prefix-efault/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-1/`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-1_partial_read_efault.c`
- `/home/chin39/Documents/play/specula-profile/reports/patch-validation-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-04-both.txt`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-1/`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-04`)

## Caveats

- Known upstream mechanism (#711). The catalog records it for tracking and for
  its file/offset evidence, not as a novel bug.
- The Linux control ran on tmpfs and ext4, with a separately compiled binary.
- The v5 A/B evidence is historical at `604948581`. No runtime run on current
  main.
- `repro/run.sh` compiles inside the guest with `cc`. The stock initramfs has no
  compiler. See `docs/running-reproducers.md`.
