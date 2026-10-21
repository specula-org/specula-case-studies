# Validation Changelog

## Round 1 - Trace Validation

- [fix] Trace bootstrap selection: used each harness-generated cfg so `InitialSharedOffset`, `InitialFileSize`, and `InitialCacheCapacity` match the captured trace; the shared template generated zero initial states and was rejected as false-positive evidence.
- [fix] Trace invariant wiring: retained `TraceMatched`, full `ValidatePostState`, and structural invariants while disabling scenario bug oracles in trace configs; the hunting configs remain the sole place those oracles are enabled.
- [fix] `InodeHandle*AcquireOffset`: moved the timebox start after the blocking offset-lock call; the previous interval let a competing acquire replay before operations that completed while it was blocked (Trace: `specula-ramfs_fault_vector-contention-prefix.ndjson`).
- [fix] RamFS contention harness: gated only `.specula_ramfs_fault_vector` so the scalar commits between vector iovecs 1 and 2; replaced the artificial 20% blocked-lock overlap gate with an exact commit-order check.
- [fix] `DoSysReadvHandleEntry`: continued on a fully consumed destination iovec (`entryCopied`) rather than the adapter's shorter logical return (`entryReturned`), matching `writer.has_avail()` (Trace: `specula-exfat_fault_vector.ndjson`).
- [fix] `InodeHandleReleaseOffset`: emitted the release-shadow transition before dropping the real guard, preventing a successor acquire from overtaking and corrupting `offsetOwner` observations (Trace: `specula-ramfs_fault_vector.ndjson`).
- [fix] `ViablePIDs`: ordered overlapping events by completion when their captured shared post-states conflict; commuting overlaps remain unordered (Trace: `specula-correct_vector_positional.ndjson`).

## Round 1 - Model Checking

- [bug] `MCReadReturnCoversCopies`: a positive prefix copied by a later `readv` iovec is discarded on `EFAULT`; the syscall reports only the prior iovec and leaves the shared offset behind the user-visible copy (Case C).
- [bug] `MCNoReadPastEOF`: RamFS and exFAT compute a logical EOF limit but let the page cache copy against its larger aligned capacity, so bytes beyond EOF can alter the destination (Case C).
- [bug] `MCNoNominalEOFOnFault`: RamFS publishes the full requested end before copying and does not roll it back when the user copy faults with zero progress (Case C).
- [bug] `MCVectorSingleLinearization`: a competing shared-offset operation can commit between two `readv`/`writev` entries because each entry acquires and releases the offset lock independently (Case C).
- No Case A or Case B repair was required. `MC.cfg` exhausted 511,868 distinct states with all convergence invariants holding; its last periodic progress line was depth 12.

## Result

Converged in 1 round. Bug hunting: 4 bugs found.
