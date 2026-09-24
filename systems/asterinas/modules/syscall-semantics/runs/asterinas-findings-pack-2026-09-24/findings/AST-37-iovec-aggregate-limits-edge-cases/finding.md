# AST-37: Iovec aggregate limits and edge cases need contract checks

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report T-6/CR-4 (same IDs in the modeling brief, T-6 shared with AST-38), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | readv, writev, preadv, pwritev, preadv2, pwritev2, sendmsg, recvmsg |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-matches: [#1245](https://github.com/asterinas/asterinas/issues/1245), [#2471](https://github.com/asterinas/asterinas/pull/2471) |
| Fix | unfixed for the aggregate cap. The NULL-base sub-case was changed upstream by [#3720](https://github.com/asterinas/asterinas/pull/3720), see Caveats |
| Reproducer | NOT_RUN |

## Summary

The shared iovec importer caps the total length of a vectored call at
`isize::MAX`, while Linux truncates it to `MAX_RW_COUNT`. At the pin it also
treated an entry with a NULL base and a nonzero length as empty instead of
faulting. Aliased and overlapping iovecs are accepted without a documented
result. None of these has been shown to break a supported contract, so the
entry is a set of contract checks rather than a bug.

## Linux contract

Linux caps the total transfer of a vectored call at `MAX_RW_COUNT`
(`INT_MAX & PAGE_MASK`, 0x7ffff000 with 4 KiB pages) and silently ignores the
rest (Recon cites Linux v6.16 `lib/iov_iter.c:1464-1494`). readv(2) and
writev(2) require EINVAL when the sum of lengths overflows `ssize_t` and
process the iovecs in array order. Linux checks every captured range, so a
NULL base with a nonzero length fails with EFAULT. Linux does not promise a
single snapshot of an iovec array that another thread is modifying.

## Asterinas behavior

- `kernel/core/src/util/iovec.rs::copy_iovs_and_convert` accepts at most 1024
  entries (`MAX_IO_VECTOR_LENGTH`) and truncates the running total at
  `MAX_TOTAL_IOV_BYTES = isize::MAX`. The doc comment on that constant cites
  Linux's truncation and explains that the larger bound is a guard against
  future overflow.
- `kernel/core/src/util/iovec.rs::IoVec::is_empty` returns true when
  `base == 0`, so a NULL base with a nonzero length is skipped.
- Untyped OSTD copies accept overlapping ranges and their documentation
  promises no defined result for overlap (`ostd/src/mm/io/mod.rs`, lines
  295-311 at the pin).
- Recon rejected one suspicion. The `start_addr + idx * size_of::<UserIoVec>()`
  wrap is unreachable, because the count is at most 1024 and a start high
  enough to wrap fails the first entry's bound check.

## Reproduction

No runtime reproducer exists. Recon T-6 lists null/nonzero, aliases,
overlap, the aggregate cap and zero-length entries. The expected outcome is
that all stay bounded and contained.

1. Aggregate cap. Map one 4 MiB region and build 1024 iovecs that all point
   at it, for 4 GiB in total. Call `writev` on `/dev/null` and `readv` on
   `/dev/zero`. Linux returns 2147479552 (0x7ffff000) for both. A larger
   count, up to 4294967296, shows the contract difference.
2. NULL base. Call `writev` on a regular file with one iovec `{NULL, 16}`.
   Linux returns -1 with EFAULT. At the pin the source predicts a return of 0
   with no error.
3. Alias and overlap. Call `readv` from a file into two iovecs that overlap
   in user memory, and `writev` from overlapping iovecs. Linux handles the
   entries in order, so the later entry's bytes win in the overlap. Check for
   no panic, a result bounded by the request, and contents consistent with
   in-order handling.

SMP=1 is enough for all three.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. The large-iovec allocation panic (#1245) and the
`preadv`/`pwritev` argument fix (#2471) are distinct from the remaining
aggregate `MAX_RW_COUNT` and alias/overlap questions. The Recon code-review
item CR-4 asks the project to decide and document the aggregate bound.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 5.5 #3720, 6.1, 6.7, 7, 9.2 T-6, 9.3 CR-4, 10)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 4, section 6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/inventory.json` (PR #3720 state)

## Caveats

- The register says "MAX_RW_COUNT versus isize::MAX and alias/overlap cases;
  no confirmed bug". The `isize::MAX` bound is a documented design choice,
  so the aggregate item may end as a compatibility decision rather than a
  defect.
- Recon routed the NULL-base case to PR #3720, which was open and absent from
  the pin at the time. The dedup inventory records #3720 as merged on
  2026-08-27, but the dedup did not list it for AST-37. At upstream main
  `bc12195`, `IoVec::is_empty` checks only `len == 0` and each range is
  validated with `mm::is_in_user_space`, while `MAX_TOTAL_IOV_BYTES` is still
  `isize::MAX` (package-builder `git show`, 2026-09-24). Retest the NULL-base
  case on the target revision before reporting it.
- Recon T-6 also covers AST-38. That batch-length question is tracked
  separately.
