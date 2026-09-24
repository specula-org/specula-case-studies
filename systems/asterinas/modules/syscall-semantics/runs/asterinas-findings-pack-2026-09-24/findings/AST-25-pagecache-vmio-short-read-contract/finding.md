# AST-25: PageCache/VmIo no-short-read contract versus capacity clamp

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding CR-1 (contract remainder), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none. The same raw finding 01b CR-1 has the native verdict REPRODUCED. That verdict belongs to its syscall effect, tracked as AST-05. |
| Syscalls | `read`, `pread64` (the callers exercised by CR-1). The contract question itself is internal. |
| Upstream | none (NO_DIRECT_MATCH). Reviewed, not matching: #3778 (open, fixes caller over-delivery), #3729 (open, RWF_NOWAIT no-wait APIs), #2953 (merged page-cache refactor) |
| Fix | unfixed. Assess after the caller fixes land. |
| Reproducer | none of its own. The CR-1 runtime test demonstrates AST-05's syscall effect, not an independent AST-25 consequence. |

## Summary

`ostd`'s `VmIo::read` promises "no short reads": success means the writer was
filled completely. `PageCache` implements `VmIo` by delegating to `Vmo::read`,
which clamps the copy to the page-aligned VMO capacity and returns success
after a short or zero-length transfer. The reproduced harm (ramfs and exFAT
reads storing bytes past the returned count) is AST-05. AST-25 is the remaining
question of whether the contract mismatch itself can harm any other supported
caller once the ramfs and exFAT callers are fixed.

## Linux contract

There is no direct Linux-visible contract for this internal API. The
Linux-visible consequence found so far is read(2)'s rule that only the returned
number of bytes is stored in the buffer, which AST-05 tracks. The internal
contract is the `VmIo::read` documentation at the pin
(`ostd/src/mm/io/mod.rs`): "On success, the `writer` must be written with the
requested data completely. If, for any reason, the requested data is only
partially available, then the method shall return an error."

## Asterinas behavior

At the pin:

- `ostd/src/mm/io/mod.rs::VmIo::read` states the all-or-error contract.
- `kernel/core/src/vm/page_cache/mod.rs::<PageCache as VmIo>::read` calls
  `self.0.read(offset, writer)` and returns `Ok(())`.
- `kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::read` computes
  `read_len = writer.avail().min(self.size().saturating_sub(offset))`, returns
  `Ok(())` when that is 0, and otherwise copies only `read_len` bytes.
- The other `VmIo` families enforce the contract: the `HasVmReaderWriter`
  blanket impl in `ostd/src/mm/io/util.rs` returns `Error::InvalidArgs` when the
  request exceeds the source, and `IoMem` checks the range first and offers a
  separate `read_fallible` for partial progress.
- ext2's `read_at` limits the writer to the file-size-clamped length, so the
  clamp cannot bind. ramfs and exFAT passed the unlimited user writer (AST-05).
- The 01b CR-1 investigation classified the fixed-size callers
  (`read_bytes`/`read_val` for the ext2 symlink and inode table, the exFAT
  dentry iterator, `delete_dentry_set`, and `meta_cache`) as in range today, so
  the clamp is latent there. It called the zero-capacity branch benign today
  because every caller clamps to 0 first.

## Reproduction

No AST-25-specific reproducer exists. The 01b CR-1 test
(`/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-1_vmo_overdelivery.c`)
showed a sequential `pread(fd, buf, 8192, 0)` of a 100-byte ramfs or exFAT file
returning 100 while overwriting bytes `[100, 4096)`, and an EOF `pread`
returning 0 while overwriting 3996 bytes. ext2 stayed clean. That is AST-05's
effect and is packaged as an AST-05 extra. A reproducer for AST-25 would need a
supported caller, other than the ramfs and exFAT read paths, whose request can
exceed the VMO capacity and whose short success causes an observable wrong
result.

## Fix and upstream status

Register: "Its reproduced syscall effect is AST-05; independent residual harm
after caller fixes remains unverified." The 01b handoff worklist says to assess
AST-25 after the caller fixes and to require a supported caller and an
independent residual consequence before promotion. matches.json: #3778 fixes
caller over-delivery and #3729 adds no-wait APIs. Neither resolves the
all-or-error contract question across other callers. The 01b CR-1
recommendation was to make `PageCache as VmIo` return an error when
`offset + avail` exceeds capacity and to give filesystems an explicit clamped
read that returns a count. A related source note in the PR #3778 second review
observes that ramfs `write_at`/`resize` publish the size before a fallible
`page_cache.resize` with no rollback, after which `metadata.size` could exceed
the VMO size and reads would over-count through the same silent clamp. That note
was not run.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 9)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/CR-1/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/repro/test_bugCR-1_guest.log
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md
- /home/chin39/Documents/play/specula-profile/references/pr-3778-handoff.md (section "Second review")

## Caveats

- SOURCE LEAD. The raw 01b CR-1 verdict REPRODUCED is not this entry's status.
  The register splits CR-1 into AST-05 (reproduced effect) and AST-25 (contract
  follow-up).
- The exFAT over-delivered tail in CR-1 was zeros, so no stale-data leak was
  observed.
- The latent-caller analysis is static and dates from the pin. Callers added
  later were not reviewed.
