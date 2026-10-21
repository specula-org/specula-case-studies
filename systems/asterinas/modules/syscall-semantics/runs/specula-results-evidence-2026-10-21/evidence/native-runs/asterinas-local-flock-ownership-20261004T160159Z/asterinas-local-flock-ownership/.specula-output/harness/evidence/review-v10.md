# Independent corrective review of flock harness v10

Verdict: **PASS for the exact v10 revision**. The author-reported R6 failed-lookup interval issue is confirmed and closed by this correction. R1-R5 remain closed. The reviewed v9 early-console arguments are included unchanged. The controller may renew the changed hash entries and resume bounded verification under the shared resource policy.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T14:06:21.685092+00:00.

The reviewed frozen proposal is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v10`, including inputs, hash manifest, diff and reason. Every input matches its recorded hash. Only these artifacts differ from v9:

| File | SHA-256 |
|---|---|
| `patches/instrumentation.patch` | `538d875e348e4298f6d16241cec9104f263dc87402a9e5ed900c54b4f1154e84` |
| `src/flock_trace.rs` | `fa816500a3721fb16a8a6a73c82c9ce62c60681e3f90a067ac831feefd0e48ce` |

## R6 disposition

**CLOSED.** Before the actual `get_file_fast!` expansion, the instrumented syscall captures a real timestamp and saves it in the acting task's existing scalar storage while its trace continuation is `lookup`. The wrapper emits `GetFileFastBadFd` only when the real call returned EBADF and that continuation remains at `lookup`. It now uses the saved pre-lookup start instead of starting the interval after the error returned.

The pinned shared-table macro obtains a read guard and then calls `get_file`; its `?` returns on EBADF before any file Arc clone. That failure path cannot overwrite the saved timestamp through the tracked-file clone hook. The real failed lookup and read-guard release are therefore inside the emitted interval. A competing FD insertion in the former release-to-emission gap can overlap this interval, allowing the full Trace/base guards to select the valid earlier failed lookup.

Successful lookups continue to use their original local `trace_start` and the same actual borrow/clone packet. A successful clone may update `saved_start` as before, but the failure wrapper cannot consume that value because successful capture moves the continuation away from `lookup`. No expected outcome is synthesized, no event or field is removed, and no Arc ownership, file-table guard, model action, invariant or oracle changes.

The new helper accesses only the existing per-task storage through the reviewed task-local writer. It adds no shared lock or allocation. No material defect was identified in this focused correction. The trigger is a static source audit, not an observed runtime mismatch. The controller reports that v9 was not executed before this proposal.

The reviewer used file reads and hashes only, modified no source/harness input, ran no build, guest, tests, controls, TLC or trace replay, and acquired no locks. This verdict closes the corrective review gate for the exact proposal. Boot, actual event coverage, timing quality and matching trace evidence remain execution obligations.
