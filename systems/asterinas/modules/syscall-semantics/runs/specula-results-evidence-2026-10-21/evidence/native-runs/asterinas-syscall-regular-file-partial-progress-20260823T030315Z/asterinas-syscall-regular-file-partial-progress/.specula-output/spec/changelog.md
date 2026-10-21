# Validation changelog

## Round 1 - Trace Validation

- [fix] FileOpsReadAtCopyComplete: model ramfs successful-copy progress as a page-cache-capacity abstraction instead of forcing the full request; logical EOF remains the lower bound (Trace: ramfs_normal.ndjson).
- [fix] Trace configs: separate full trace/post-state conformance from Linux-contract checking so observed violations do not prevent `TraceMatched`; all contract invariants remain enabled in their focused hunting configs (Traces: ramfs_faults.ndjson, ramfs_zero_append.ndjson, ext2_buffered.ndjson, ext2_direct.ndjson, reference_restart.ndjson).
- [fix] VmoWriteAnonymousPagesFinishSuccess: admit the documented reference interruptible backend's post-restart success event instead of requiring `Ramfs` unconditionally (Trace: reference_restart.ndjson).

## Round 1 - Model Checking

- [fix-inv] MCNoPermanentLocks: remove `SYMMETRY` from `MC.cfg` because TLC warns that symmetry reduction can miss liveness violations; the first 30-minute safety run reached depth 21 with 51,917,782 generated and 12,932,269 distinct states before the time budget (Case A).

## Round 2 - Trace Validation

- No regressions: all six pinned traces and the reference-capability trace passed without further changes.

## Bug Hunting

- [bug] ReportedCoversVisibleCopy: a positive regular-file read prefix is visible in user memory but the syscall returns `EFAULT` with no reported or shared-offset progress.
- [bug] MixedPageRetainedPrefixReported: ext2 can retain an earlier dirty write prefix when a later `Uninit` page faults, then return `EFAULT` with no reported or shared-offset progress.
- [bug] ReportedCoversVisibleCopy: ramfs can copy to page-cache capacity beyond logical EOF while returning only the earlier EOF-derived length.
- [bug] FileSizeMatchesProgress: ramfs can publish an extending size before a zero-copy fault or zero-length write and does not roll it back.
- [bug] VectorCallLinearizable: readv/writev release OFD serialization between iovecs, permitting a conflicting shared operation or delayed effect in the gap.
- [bug] NoUnaccountedPendingEffect: ext2 direct I/O can return from a later range fault while an earlier submitted BIO remains live.
- [bug] SharedOffsetMatchesReported: a zero-copy `O_APPEND` failure leaves the shared OFD offset at EOF.

## Result

Converged in 2 rounds. Bug hunting: 7 pinned-code bugs found. Both Scenario 6 violations require the reference-only interruptible backend and are not pinned ext2/ramfs findings.
