# AST-26: Regular-file partial-progress EINTR restart candidate

| Field | Value |
|---|---|
| Evidence status | FALSE POSITIVE |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding CR-1, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none. GLM `asterinas-glm53-eval-20260826T035049Z` CR-2 reached the same wrapper asymmetry on pipes (REPRODUCED). That is AST-09, a different entry. |
| Syscalls | `read`, `write` on regular files (ramfs, ext2 buffered, `O_DIRECT`, `O_SYNC`) |
| Upstream | none for this candidate (NON_ACTIONABLE_RECORD). Related records: #1578 (closed, restart signal-interrupted syscalls), #3576 (open, refactors the syscall restart mechanism and rewrites the same lines) |
| Fix | not applicable |
| Reproducer | repro/ (negative probe, ran at 604948581 with SMP=2, no regular-file EINTR observed) |

## Summary

The candidate claimed that `sys_read`/`sys_write` turn any backend `EINTR` into
`ERESTARTSYS` without recording committed progress, so an `SA_RESTART` replay
could repeat a partial transfer, for example appending an `O_APPEND` payload
twice. The precondition never occurs: no regular-file backend at the pin
returns `EINTR`. A signal storm against large regular-file reads and writes
produced zero `EINTR` and no replay, matching Linux.

## Linux contract

signal(7): `read`, `readv`, `write`, `writev` on "slow" devices are restarted
under `SA_RESTART`, and "a (local) disk is not a slow device according to this
definition; I/O operations on disk devices are not interrupted by signals."
read(2) and write(2): a call interrupted after transferring some data returns
the partial count. The Linux control ran the same binary (tmpfs and `O_SYNC`)
and printed `UNINTERRUPTIBLE`, `NO_REPLAY`, and `NO_DOUBLE_ADVANCE`.

## Asterinas behavior

At the pin, `kernel/core/src/syscall/read.rs::sys_read` and
`kernel/core/src/syscall/write.rs::sys_write` map `Errno::EINTR` to
`ERESTARTSYS` with no byte count, and
`kernel/core/src/process/signal/mod.rs::handle_pending_signal` replays the
syscall with the original arguments under `SA_RESTART`. The structural reading
is accurate. The claimed harm needs a regular-file `read_at`/`write_at` that
commits a prefix and then returns `EINTR`. The 01a confirmation found no
producer: `grep -rn EINTR` over the pristine `kernel/core/src/fs/`,
`kernel/core/src/vm/`, and `ostd/src/` returned nothing, regular-file waits use
the uninterruptible `wait_until`, and user-buffer faults surface as `EFAULT`.
The pipe, socket, TTY, and inotify callers that can return `EINTR` do so only at
zero progress. The only emitter of the precondition was the harness-only
`ReferenceFileOps` mock.

Observed at the pin (01a CR-1):

```
CR1_CTRL_PIPE restart=1 ret=1 errno=0 handler_hits=130 sigs_sent=130 verdict=RESTARTED
CR1_CTRL_PIPE restart=0 ret=-1 errno=4 handler_hits=2 sigs_sent=2 verdict=EINTR
CR1_PROBE ramfs mode=0 ... wr_eintr=0 ... rd_eintr=0 ... verdict=UNINTERRUPTIBLE
CR1_APPEND ramfs iters=128 returned=8388608 size=8388608 ... verdict=NO_REPLAY
CR1_PROBE ext2direct mode=1 ... wr_eintr=0 ... rd_eintr=0 ... verdict=UNINTERRUPTIBLE
CR1_OFFSET ext2sync iters=128 returned=8388608 offset=8388608 size=8388608 ... verdict=NO_DOUBLE_ADVANCE
```

The pipe positive control shows the restart arm is live on this kernel, so the
regular-file negatives are meaningful.

## Reproduction

`repro/test_bugCR-1_restart_progress_provenance.c` is a negative probe: a
signal-storm thread targets large regular-file reads and writes, with and
without `SA_RESTART`, plus a pipe positive control. See `repro/README.md`. It is
useful for deduplicating a new regular-file restart report and for checking
that a future backend change has not introduced a regular-file `EINTR`.

## Fix and upstream status

Register: "Required regular-file EINTR path absent; pipe AST-09 has a different
scope." matches.json: NON_ACTIONABLE_RECORD, upstream fix status NOT_APPLICABLE,
"Reachable pipe/socket restart reports do not turn this old regular-file
candidate into a confirmed bug." The 01a confirmation suggested two
non-behavioral steps: document at `read.rs`/`write.rs` and in the `FileOps`
trait that `EINTR` implies zero committed progress, and track the design
against PR #3576, which rewrites these lines but still encodes restartability
as a bare errno.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmed-bugs.md (Entry 8)
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/CR-1/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/CR-1/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/out_bugCR-1/
- /home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/analysis-report.md (F7)
- /home/chin39/Documents/play/specula-profile/references/active-specula-run-handoff.md (01a completion record)
- /home/chin39/Documents/play/specula-profile/reports/glm53-eval-final-report.md (CR-2 discussion)

## Caveats

- The FALSE POSITIVE covers regular files only. The same wrapper asymmetry is
  reachable on pipes through `readv`/`writev` (AST-09) and remains an open
  question for sockets (AST-39).
- The same run's analysis report had already predicted the outcome (F7,
  "Positive-progress regular-file restart replay is not reachable on inspected
  paths"). The confirmation verified it at runtime.
- The "no producer" conclusion is a property of the pin's backends. A future
  backend that returns `EINTR` after committing bytes would revive the hazard.
- The driver expects `confirmation/CR-1/worktree`, which no longer exists in the
  run directory.
