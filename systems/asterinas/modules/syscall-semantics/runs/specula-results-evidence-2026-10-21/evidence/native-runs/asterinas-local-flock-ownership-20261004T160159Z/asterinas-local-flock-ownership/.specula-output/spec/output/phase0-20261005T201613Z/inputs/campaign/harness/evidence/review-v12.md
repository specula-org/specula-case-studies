# Independent corrective review of flock harness v12

Verdict: **PASS for the exact v12 revision**. R8 is closed by the observed-placement setup and revised wait points. R1-R7 remain closed. The controller may renew the changed hash entries and execute the declared bounded cases under the existing resource policy. This verdict does not claim that the new cases have run or reached the required overlap fraction.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T14:31:37.064113+00:00.

The reviewed frozen proposal is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v12`, including inputs, `sha256.json`, `revision.diff` and `reason.md`. Every input matches its manifest. The changed artifacts relative to v11 are:

| File | SHA-256 |
|---|---|
| `patches/instrumentation.patch` | `a35ec5c07070319ad11102a08988f1b8838d4eb8325d2c3334b8600e93f2b9d4` |
| `src/collect.py` | `4a89527db5b15f78a686a1a8ccaecd9d60a38d5373d2f943f58ee85c21d4a2d2` |
| `src/flock_trace.rs` | `a7e0eb2562a20ee1510745614fa6fe71aabdd9f2d98f5910b243349831a5bf8d` |
| `src/scenarios.c` | `3c00e9c5b2710c2c299af2b05748dd2f990f8b22a375f510696d9fc082915a37` |

The v11 case list and all other manifest entries remain unchanged. The baseline remains `0c60537098f4c2949ad2d382aaf499de72263d76`.

## R8 disposition

**CLOSED for the declared pinned-kernel fixture.** Each worker reports its actual `SYS_getcpu` result, publishes readiness, and waits for the controller's role assignment before reading its final logical tid or registering with the trace module. The release/acquire readiness handshake orders those ordinary scalar writes. The controller verifies that its own observed CPU has not changed, assigns tid2 to the helper on another CPU and tid3 to the helper on its own CPU, and rejects any unsuitable placement before `start_open_window` is called.

The pinned `sys_getcpu` reads the actual current CPU and permits null node/cache arguments, matching the fixture call. The pinned `ClassScheduler::select_cpu` returns an existing `last_cpu` on later enqueues. No affinity or scheduler behavior is patched. The proposal correctly avoids assuming that post-creation affinity causes migration, or that `PosixThreadBuilder` inherits a narrowed parent mask: that builder initializes a full CPU set in this source pin.

The first opener can now hold its real preemption-disabling table guard while the controller runs on the other CPU. The contender shares the controller's CPU but calls `Task::yield_now` while waiting before both its `FileTableInsert` start timestamp and its actual table-lock attempt. It therefore cannot strand the controller behind a failed spin acquisition while the first holder awaits release. After insertion, both original-reference gates yield outside the original table guard. No scheduling call was moved inside the held spinlock, and no production guard was replaced or released early.

The logical role mapping is printed as `SPECULA_PLACEMENT` and retained in the collector's `cpu_placement` manifest field. Existing cases retain their previous role order. A setup that cannot establish the required mapping fails before the guarded protocol window and must remain incomplete rather than a kernel-failure claim.

## Trace and lifetime fidelity

R7's FD identity publication remains inside the original insertion guard. The new gate preserves real Arc counts and neither clones owners nor defers production cleanup outside its original call chain.

C00 still starts before both real opens and records both complete `SysOpen`/`FileTableInsert` pairs. The original open references remain held at the explicit prefix endpoint. No event is omitted or manufactured. The first insertion interval covers the real period in which it holds the table guard, including the second task's real `SysOpen`. The contender's newly added gate is outside its own measured insertion interval, so this correction does not manufacture overlap by widening that interval. Under the intended observed schedule, at least that holder-insertion/contender-open pair overlaps among the four cross-thread pairs. The unchanged checker must calculate the actual fraction from the runtime timestamps.

C13 keeps the same observed-insertion boundary before removing descriptor 3, then releases the original references, waits for the real open returns and closes descriptor 4. Its source lifetime sequence remains the one accepted in review-v11.md. The extra scheduling control does not change the required close/put/destructor ordering or claim a live descriptor from a returned numeric value after another thread closed it.

The collector change only stores the printed placement metadata. Model, Trace/schema, acceptance adapter, all event/post-state checks and the 20 percent threshold remain unchanged. No new material issue was identified in this focused correction.

The reviewer used file reads and content hashes only, modified no source/harness input, ran no build, guest, tests, controls, TLC or trace replay, and acquired no locks. The controller reports that v11 was not executed while R8 was open. Actual placement, complete exports, zero drops, observed overlap, C13 reference history and matching witnesses remain runtime/evidence obligations.
