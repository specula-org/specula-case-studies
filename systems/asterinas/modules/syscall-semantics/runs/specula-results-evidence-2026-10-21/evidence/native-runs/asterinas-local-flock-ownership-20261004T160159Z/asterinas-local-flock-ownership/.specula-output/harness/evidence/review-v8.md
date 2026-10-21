# Independent corrective review of flock harness v8

Verdict: **PASS for the exact v8 revision**. R5 is closed. R1-R4 remain closed, and the firmware correction accepted in review-v7.md remains included. The controller may renew the exact-version marker and resume bounded verification under the shared resource policy. This is a source-review verdict, not a successful boot or trace-validation result.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T13:55:40.556498+00:00.

The reviewed frozen proposal is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v8`, including its `inputs`, `sha256.json`, `revision.diff` and `reason.md`. All input files match the manifest. Only the following semantic artifacts differ from v7:

| File | SHA-256 |
|---|---|
| `patches/instrumentation.patch` | `2413915f88e390cce8f52b90720b546d14e1178691b8a121e74583d12f5812bb` |
| `src/flock_trace.rs` | `50eaa8b463889605d5ebb5f3fe836678573e12b6064aaa2f7894fbe866260a90` |

The full unchanged hash set remains recorded in v8's manifest and prior reviews. The baseline is `0c60537098f4c2949ad2d382aaf499de72263d76`.

## R5 disposition

**CLOSED.** Before assignment, `try_set_lock` now saves only the selected one-based index and old queue token in the acting task's preallocated trace storage. It emits no event and changes no modeled local continuation at that point. The production `list[idx] = req_lock.clone()` expression and existing list Mutex remain unchanged.

The replacement event is now emitted inside the real `FlockItem::drop`, after entering that destructor and before its production `wake_all`. `take_replacement` accepts the pending marker only while the acting task is at `tryCheck`, when the destructor's queue token is nonzero and matches the saved old token. The saved index is nonzero because the sole call site stores `idx + 1`. A successful match clears the marker before event emission. Request and retain-removal drops retain their existing distinct dispatch paths.

The marker is scalar and local to the registered task. It adds no Arc/Weak ownership, allocation, shared lock, queue mutation or deferred destructor. The old queue identity comes from the actual selected list slot under its original Mutex and is checked against the actual item being destroyed. The request uses a fresh token, so its clone does not alias the old queue marker. A thread paused before the assignment can no longer export `TrySetLockReplace` or a drain continuation early.

No new material issue was identified in this focused correction. The trace schema, full base guards, exact post-state checks, source mode-conversion behavior and final-release paths remain unchanged. The accepted v7 firmware option remains the only boot-configuration difference from the previously attempted VM.

The reviewer used file reads and hashes only, changed no source/harness input, ran no build, guest, tests, controls, TLC or trace replay, and acquired no locks. The controller reports no dependent rerun while R5 was open. Boot success, actual event occurrence, raw timing quality, Linux controls and matching trace witnesses remain execution/evidence obligations.
