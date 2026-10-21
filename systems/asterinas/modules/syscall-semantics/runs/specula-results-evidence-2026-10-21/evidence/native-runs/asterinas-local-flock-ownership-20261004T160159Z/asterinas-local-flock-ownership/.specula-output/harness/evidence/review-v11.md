# Independent corrective review of flock harness v11

Verdict: **NEEDS_IMPROVEMENT**. R7 is closed, and the new prefix/overlap construction preserves real trace semantics. R8 below remains open because the guard-held scheduling gate can prevent its own controller from running. R1-R6 remain closed. No dependent verification of v11 is approved by this artifact.

Reviewer: `/root/harness_review`, independent from the harness author. Date: 2026-10-05T14:23:44.470224+00:00.

The reviewed frozen proposal is `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/harness/evidence/revision-v11`, including inputs, `sha256.json`, `revision.diff` and `reason.md`. Every snapshot file matches its manifest. The changed artifacts are:

| File | SHA-256 |
|---|---|
| `patches/instrumentation.patch` | `1935540fd3ff51fefd65d3f61dae6ba3b69af4f713953366a368461be4fde47a` |
| `run.sh` | `853b535c03cd87bfed2736f361c6ec57204587618acc20b7e5d02d47bb5d3058` |
| `src/flock_trace.rs` | `80cfbce651feb676cd6ca9f4a691d5ffe6fd530f622e1b6ca567bfef264e547a` |
| `src/scenarios.c` | `e02cb559c53316b38282e1275d6c0c1f80487bb0d89721079dde7353e0aebc92` |

All other manifest entries retain their v10 hashes, including the collector, overlap checker, private alloc patch and validation invocation. The review did not change source/harness inputs, run builds, guests, tests, controls, TLC or trace replay, or acquire locks.

## R7 disposition

**CLOSED.** The scalar FD-to-OFD map is now published immediately after the real insertion while the original `RwArc<FileTable>` write guard is still held. A close operation reads and clears that map while holding the same production table guard. Therefore a close cannot observe the installed descriptor before its scalar identity is published, and the opener cannot overwrite the close's cleared value after releasing the guard. No new lock or reference is added. The clone count and insertion packet still come from the actual operation.

## Prefix and overlap assessment

C00 starts before the two real fixture opens. Each worker records its actual `SysOpen` and `FileTableInsert`, then remains paused with its original open-local Arc still held. The explicit two-events-per-worker assertions and `prefix=true` endpoint preserve all published events. No Arc put, syscall return, destructor completion or successful full case is manufactured. The unused controller stream may remain empty.

The first interval retains its existing start before the table operation and end after the original guard release. The second worker records a real open admission and starts its real insertion interval before the first guard is released. If the fixture progresses as intended, the resulting cross-thread overlap is a real consequence of this declared scheduling fixture. It does not edit timestamps, enlarge them in preprocessing, discard events or relax the 20 percent criterion. The four-event prefix exercises a narrow open/reference/table interaction and must not be described as a completed flock case or as the overlap fraction of the longer flock traces.

C13 extends the same window. It closes descriptor 3 only after both insertions are observed, while both original open-local references remain held. It then releases the originals, waits for both real open calls to return, and closes descriptor 4. This is a meaningful reference-lifetime case under the fixture's established lowest-free FD domain. Successful return of descriptor 3 after another thread removed it is retained as the actual open result, not treated as a fresh live descriptor. Runtime inspection must still confirm the recorded identities and last-put/destructor sequence.

These source assessments do not claim that C00/C13 have executed or met the quality threshold.

## R8. Guard gate may strand its controller on the same nonpreemptible CPU

`src/flock_trace.rs` adds `open_guard_window`, which spins on `OPEN_RELEASE_GUARD` while the original file-table write guard remains held. `src/scenarios.c` requires the main controller to observe stage 1, start the second worker, observe stage 2, and call the release control operation.

The exact table lock is important: `ostd/src/sync/rwarc.rs:49` returns `RwLockWriteGuard<PreemptDisabled>`. `ostd/src/sync/guard.rs:37-47` implements that guardian with `disable_preempt`. Thus the successful first opener cannot be preempted while it is waiting inside the gate. If the controller and first opener are placed on the same guest CPU, the controller cannot regain that CPU to start the second worker or release the guard. This is introduced by the fixture gate and is not a production flock deadlock.

The new case does not establish actual CPU placement. SMP=2 alone is insufficient. The pinned scheduler chooses a CPU at initial enqueue and reuses `last_cpu` later (`kernel/core/src/sched/sched_class/mod.rs:293-296`). Its `sched_setaffinity` implementation explicitly states that it does not migrate a thread already running on another CPU (`kernel/core/src/syscall/sched_affinity.rs:33-36`). Consequently, setting thread affinity after creation would not by itself close this finding.

Disposition: **OPEN**. Arrange and record a source-supported topology before enabling the window, with the nonpreemptible holder on a different CPU from its releaser. If using inherited affinity, establish it before spawning and verify actual guest CPU placement. Alternatively, use an equivalent scheduling gate that cannot depend on a releaser stranded behind the held CPU. Preserve the real table lock, reference operations, interval boundaries, all events and strict quality criterion. Review the exact correction before dependent execution. A watchdog caused by this gate must remain a harness failure/incomplete case, never a kernel defect.

The earlier v10 run outcomes are controller evidence and are preserved separately. This review does not rerun or reinterpret those results. Its only new material finding is R8.
